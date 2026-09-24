import Foundation
import OSLog
import SwiftData
import os.signpost

private let logger = Logger(subsystem: "com.feeder.app", category: "SyncEngine")

// MARK: - UserDefaults keys

/// Period (seconds) between automatic background syncs.
nonisolated let syncIntervalUserDefaultsKey = "sync_interval"
/// Number of days of article history the app retains on device.
nonisolated let articleKeepDaysUserDefaultsKey = "article_keep_days"
/// Timestamp of the last successful sync completion.
nonisolated let lastSyncDateUserDefaultsKey = "lastSyncDate"

/// Maximum age for articles, in days. Nothing older is fetched or persisted,
/// and an older row is purged.
nonisolated var articleKeepDays: Int {
  let stored = UserDefaults.standard.integer(forKey: articleKeepDaysUserDefaultsKey)
  return stored > 0 ? stored : 7
}

nonisolated var maxArticleAge: TimeInterval {
  TimeInterval(articleKeepDays) * 24 * 60 * 60
}

/// Fixed 30-day ceiling for the disk purge: the largest value the keep-days
/// picker offers.
nonisolated let maxRetentionAge: TimeInterval = 30 * 24 * 60 * 60

/// Current cutoff date. An article older than this is hidden from the UI.
nonisolated func articleCutoffDate() -> Date {
  Date().addingTimeInterval(-maxArticleAge)
}

// MARK: - SyncError

/// Categorised sync failure, so a view picks a contextual recovery action
/// without parsing a free-form error string. The case discriminates the
/// action; `message` carries the localized description.
nonisolated enum SyncError: Error, Sendable, Equatable {
  /// Offline, timeout, dropped connection, or transient server failure. The
  /// user retries once the network is reachable.
  case network(String)
  /// Feedbin returned 401. The user re-enters the credentials in Settings.
  case authFailed(String)
  /// Anything else, such as a decoding failure or a non-auth HTTP error. The
  /// UI surfaces the message and the user retries manually.
  case other(String)

  /// Localized message suitable for inline secondary-styled UI.
  var message: String {
    switch self {
    case .network(let message), .authFailed(let message), .other(let message): message
    }
  }

  /// True for a connectivity or transient transport failure, so
  /// `EntryListView` shows the offline empty state instead of "No Articles".
  var isNetworkError: Bool {
    if case .network = self { return true }
    return false
  }
}

/// Map any thrown error into a `SyncError`. Pure and `nonisolated`, so any
/// actor can categorise without hopping isolation.
nonisolated func categorizeSyncError(_ error: Error) -> SyncError {
  if let urlError = error as? URLError {
    switch urlError.code {
    case .notConnectedToInternet, .timedOut, .networkConnectionLost,
      .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
      .resourceUnavailable, .internationalRoamingOff, .callIsActive,
      .dataNotAllowed:
      return .network(urlError.localizedDescription)
    default:
      break
    }
  }
  if let feedbinError = error as? FeedbinError {
    switch feedbinError {
    case .unauthorized:
      return .authFailed(feedbinError.localizedDescription)
    case .httpError(let statusCode) where (500...599).contains(statusCode):
      return .network(feedbinError.localizedDescription)
    default:
      break
    }
  }
  return .other(error.localizedDescription)
}

/// Fetch extracted content for a batch of entries with a concurrency limit of 8.
nonisolated func fetchExtractedContentBatch(
  requests: [(entryID: Int, url: String)],
  using client: any FeedbinClientProtocol
) async -> [(entryID: Int, content: String)] {
  await withTaskGroup(
    of: (Int, String?).self,
    returning: [(entryID: Int, content: String)].self
  ) { group in
    var active = 0
    var collected: [(entryID: Int, content: String)] = []

    for request in requests {
      if active >= 8 {
        if let result = await group.next(), let content = result.1 {
          collected.append((entryID: result.0, content: content))
        }
        active -= 1
      }
      group.addTask {
        let content = try? await client.fetchExtractedContent(from: request.url)
        return (request.entryID, content?.content)
      }
      active += 1
    }

    for await result in group {
      if let content = result.1 {
        collected.append((entryID: result.0, content: content))
      }
    }

    return collected
  }
}

/// Orchestrates Feedbin sync. Every SwiftData write is delegated to
/// `DataWriter`; this type is `@MainActor @Observable` for progress display
/// only, and processes no data on MainActor.
@MainActor
@Observable
final class SyncEngine {
  /// Keeps `sync()` and `refetchHistory()` from overlapping: either acquires
  /// the flag at the start and releases it before returning.
  private(set) var isSyncing = false
  private(set) var isFetchingContent = false
  /// The last categorised failure, or `nil` after a successful sync. Views
  /// read it to render the inline error banner and its recovery action.
  private(set) var lastError: SyncError?

  private(set) var fetchedCount: Int = 0
  private(set) var totalToFetch: Int = 0

  /// Entries changed by the most recent sync: inserts plus cross-device
  /// read-state flips. Inserts alone are not the full signal, because a flipped
  /// row moves in and out of the predicate behind the list, and `ContentView`
  /// gates its refresh on this count.
  private(set) var lastSyncChangedEntryCount: Int = 0

  /// Monotonic counter bumped after each persisted page, so `ContentView` can
  /// route a deferred article-list refresh while the sync still runs. Additive
  /// to the terminal `lastSyncChangedEntryCount` signal, never a replacement.
  private(set) var lastPersistedPageVersion: Int = 0

  /// Cutoff date for the read predicates. Updated when keep-days changes.
  private(set) var queryCutoffDate: Date = articleCutoffDate()

  /// Recalculate article cutoff from current keepDays setting.
  func refreshArticleCutoff() {
    queryCutoffDate = articleCutoffDate()
  }

  /// Last sync date, persisted so incremental sync survives a restart.
  private(set) var lastSyncDate: Date? {
    get { defaults.object(forKey: lastSyncDateUserDefaultsKey) as? Date }
    set { defaults.set(newValue, forKey: lastSyncDateUserDefaultsKey) }
  }

  /// `UserDefaults` behind `lastSyncDate` and `pendingReadIDsToSync`. A test
  /// passes an isolated suite, or parallel suites race on the shared keys.
  private let defaults: UserDefaults

  private var client: (any FeedbinClientProtocol)?
  private(set) var writer: DataWriter?
  /// Read-only companion to `writer`. Vended to the article list and sidebar,
  /// so their reads run on a separate actor and never queue behind a write.
  /// The caller owns it; the engine only holds the reference.
  private(set) var reader: DataReader?
  private var periodicSyncTask: Task<Void, Never>?
  private var backfillTask: Task<Void, Never>?
  private var extractedContentTask: Task<Void, Never>?
  private var lastProgressUpdate: ContinuousClock.Instant = .now

  private static let pendingReadKey = "pendingReadIDsToSync"

  private var pendingReadIDsToSync: Set<Int> {
    get {
      Set(defaults.array(forKey: Self.pendingReadKey) as? [Int] ?? [])
    }
    set {
      defaults.set(Array(newValue), forKey: Self.pendingReadKey)
    }
  }

  /// The default argument keeps every production call site at `SyncEngine()`.
  /// A test passes an isolated suite to stay off the standard domain.
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Configure the engine with credentials. The caller must attach a
  /// `DataWriter` through `attachWriter(_:)` before calling `sync()`.
  func configure(username: String, password: String) {
    self.client = FeedbinClient(username: username, password: password)
    logger.info("Configured sync engine. Last sync: \(self.lastSyncDate?.description ?? "never", privacy: .private).")
  }

  /// Inject the pre-built `DataWriter` this engine delegates writes to. The
  /// caller owns it and has already paid the background-init cost, so this
  /// stays synchronous.
  func attachWriter(_ writer: DataWriter) {
    self.writer = writer
  }

  /// Inject the pre-built read-only `DataReader`. Same ownership contract as
  /// `attachWriter`, and the caller must build it on the same container.
  func attachReader(_ reader: DataReader) {
    self.reader = reader
  }

  /// Inject a pre-built `FeedbinClientProtocol`. Production builds its client
  /// in `configure(username:password:)`; a test installs a fake here and never
  /// touches the network.
  func attachClient(_ client: any FeedbinClientProtocol) {
    self.client = client
  }

  /// Queue entry IDs to be pushed as read to Feedbin on next sync or explicit push.
  func queueReadIDs(_ ids: Set<Int>) {
    pendingReadIDsToSync.formUnion(ids)
  }

  /// Push any queued read IDs to Feedbin, then clear them.
  func pushPendingReads() async {
    guard let client, !pendingReadIDsToSync.isEmpty else { return }
    let ids = Array(pendingReadIDsToSync)
    do {
      try await client.deleteUnreadEntries(ids)
      pendingReadIDsToSync.removeAll()
    } catch {
      logger.error("Failed to push read state: \(error.localizedDescription)")
    }
  }

  /// Verify that the configured credentials are valid.
  func verifyCredentials() async -> Bool {
    guard let client else { return false }
    do {
      return try await client.verifyCredentials()
    } catch {
      lastError = categorizeSyncError(error)
      return false
    }
  }

  /// Start periodic background sync using structured concurrency.
  func startPeriodicSync(interval: TimeInterval = 300) {
    stopPeriodicSync()
    periodicSyncTask = Task {
      await CredentialResidue.removeFromSharedStores()
      if Task.isCancelled { return }
      await sync()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        if Task.isCancelled { break }
        await sync()
      }
    }
  }

  /// Stop periodic sync by cancelling the task.
  func stopPeriodicSync() {
    periodicSyncTask?.cancel()
    periodicSyncTask = nil
    backfillTask?.cancel()
    backfillTask = nil
    extractedContentTask?.cancel()
    extractedContentTask = nil
  }

  /// Pull subscriptions and icons, then fetch entries since the last
  /// successful sync. On the first run `since` falls back to the keep-days
  /// cutoff, so the first call already covers the full window.
  func sync() async {
    guard let client, let writer, !isSyncing else { return }

    isSyncing = true
    lastError = nil
    fetchedCount = 0
    totalToFetch = 0
    logger.info("Starting sync")

    do {
      let subscriptions = try await client.fetchSubscriptions()
      logger.info("Fetched \(subscriptions.count) subscriptions")
      try await writer.syncFeeds(subscriptions)

      // Only download an icon whose URL changed or whose data is missing.
      let icons = try await client.fetchIcons()
      let needed = try await writer.iconURLsNeedingFetch(icons)
      var iconData: [String: Data] = [:]
      for urlString in needed {
        if let url = URL(string: urlString),
          let (data, _) = try? await URLSession.shared.data(from: url)
        {
          iconData[urlString] = data
        }
      }
      try await writer.syncIcons(icons, prefetchedData: iconData)

      // Push queued local read-state changes first, so the `unreadIDs` set
      // fetched below reflects them.
      await pushPendingReads()

      // The `max` keeps a stale `lastSyncDate` from reaching further back than
      // the retention window allows. On the first sync it falls back to the
      // cutoff directly.
      let since = max(lastSyncDate ?? queryCutoffDate, queryCutoffDate)
      let changed = try await fetchEntriesSince(since, using: client, writer: writer)

      lastSyncDate = Date()
      fetchedCount = 0
      totalToFetch = 0
      lastSyncChangedEntryCount = changed
      isSyncing = false

      startExtractedContentFetch()

      logger.info("Primary sync complete")
    } catch {
      lastError = categorizeSyncError(error)

      logger.error("Sync failed: \(error.localizedDescription)")
      lastSyncChangedEntryCount = 0
      isSyncing = false
    }
  }

  // MARK: - Entry fetch

  /// The single entry-fetch path behind both `sync()` and `refetchHistory()`;
  /// the caller picks `since`. Each page persists with the server's current
  /// unread-IDs set, and the full read-state map syncs afterwards so rows
  /// outside the paged window converge too. Returns the changed-row count —
  /// inserts plus read-state flips — so a caller can gate a UI refresh on it.
  private func fetchEntriesSince(_ since: Date, using client: any FeedbinClientProtocol, writer: DataWriter) async throws -> Int {
    let unreadIDs = try await client.fetchUnreadEntryIDs()
    let unreadIDSet = Set(unreadIDs)

    logger.info("Fetching entries since \(since.description, privacy: .private)")

    var totalNew = 0
    var totalFetched = 0
    for try await page in client.fetchAllEntryPages(since: since) {
      if let total = page.totalCount { totalToFetch = total }
      // Back-to-back persist intervals with no fetch gap between them are the
      // coordinator-saturation signature the measurement gates on.
      let persistSignpost = perfSignposter.beginInterval(PerformanceSignpostName.writePersistPage)
      let newCount = try await writer.persistEntries(page.entries, unreadIDs: unreadIDSet)
      perfSignposter.endInterval(PerformanceSignpostName.writePersistPage, persistSignpost)
      totalNew += newCount
      totalFetched += page.entries.count
      // Bumped per persisted page even when the page inserted nothing: the
      // counter's contract is "a page was processed". The downstream deferred
      // refresh channel coalesces the bumps.
      lastPersistedPageVersion &+= 1
      let now = ContinuousClock.now
      if now - lastProgressUpdate >= .milliseconds(200) {
        fetchedCount = totalFetched
        lastProgressUpdate = now
      }
      logger.info("Fetched page: \(page.entries.count) entries (\(totalFetched) total)")
    }
    fetchedCount = totalFetched

    let readStateFlips = try await writer.updateReadState(unreadIDs: unreadIDSet)

    if totalNew > 0 || readStateFlips > 0 {
      logger.info("Entry fetch: \(totalNew) new + \(readStateFlips) read-state flips")
    }

    return totalNew + readStateFlips
  }

  // MARK: - Background: Extracted content fetching

  private func startExtractedContentFetch() {
    extractedContentTask?.cancel()
    extractedContentTask = Task(priority: .utility) {
      guard let client, let writer else { return }

      isFetchingContent = true
      logger.info("Starting background extracted content fetch")

      do {
        let requests = try await writer.fetchExtractedContentRequests()
        guard !requests.isEmpty else {
          isFetchingContent = false
          return
        }

        logger.info("Fetching extracted content for \(requests.count) entries")

        let results = await fetchExtractedContentBatch(requests: requests, using: client)

        if !results.isEmpty {
          try await writer.applyExtractedContent(results: results)
        }

        logger.info("Extracted content: \(results.count) fetched")
      } catch {
        logger.error("Extracted content fetch failed: \(error.localizedDescription)")
      }

      isFetchingContent = false
    }
  }

  // MARK: - Background backfill

  /// Full-window re-fetch, called from Settings when keep-days rises, so the
  /// newly included older window fills without waiting for `lastSyncDate` to
  /// age out.
  func refetchHistory() {
    backfillTask?.cancel()
    backfillTask = Task(priority: .utility) {
      guard let client, let writer else { return }
      guard !isSyncing else {
        logger.info("Backfill skipped: another sync in progress")
        return
      }

      isSyncing = true
      defer { isSyncing = false }

      fetchedCount = 0
      totalToFetch = 0
      // Reset on entry and assign on completion, so the `isSyncing` false edge
      // reports this backfill's count. A stale value would block a legitimate
      // refresh or trigger a bogus one.
      lastSyncChangedEntryCount = 0
      var changed = 0

      logger.info("Starting keepDays-window backfill")

      do {
        changed = try await fetchEntriesSince(queryCutoffDate, using: client, writer: writer)
        logger.info("Backfill complete (\(changed) changed entries)")
      } catch {
        logger.error("Backfill failed: \(error.localizedDescription)")
        changed = 0
      }

      lastSyncChangedEntryCount = changed

      // The extracted-content fetch rides the same post-sync pipeline as
      // `sync()`.
      startExtractedContentFetch()
    }
  }

  // MARK: - Preview / test seam

  /// Seed the engine's observable state for SwiftUI previews. Production never
  /// calls it; the seam lives here so `private(set)` stays tight on the real
  /// fields. Every field it does not touch keeps its init default.
  ///
  /// Not gated behind `#if DEBUG`: preview helpers reach it from types that
  /// must still type-check in Release, even though the `#Preview` body is
  /// stripped.
  func applyPreviewState(
    isSyncing: Bool = false,
    lastSyncDate: Date? = nil,
    lastError: SyncError? = nil,
    fetchedCount: Int = 0,
    totalToFetch: Int = 0
  ) {
    self.isSyncing = isSyncing
    self.lastSyncDate = lastSyncDate
    self.lastError = lastError
    self.fetchedCount = fetchedCount
    self.totalToFetch = totalToFetch
  }
}
