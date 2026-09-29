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

// MARK: - FeedbinAccountPhase

/// `unused` belongs to a launch that never reads or saves credentials:
/// headless and previews.
nonisolated enum FeedbinAccountPhase: Equatable, Sendable {
  case checking
  case noAccount
  case signedIn(username: String)
  case unreadable
  case unused

  var isSignedIn: Bool {
    if case .signedIn = self { return true }
    return false
  }

  var signedInUsername: String? {
    if case .signedIn(let username) = self { return username }
    return nil
  }
}

// MARK: - Extracted content

typealias ExtractedContentResult = (entryID: Int, result: Result<String, ExtractedContentFailure>)

/// Sends at most 8 requests at a time. After a cancellation it starts no new
/// request, so the result has no element for an entry that it did not send.
nonisolated func fetchExtractedContentBatch(
  requests: [(entryID: Int, url: String)],
  using client: any FeedbinClientProtocol
) async -> [ExtractedContentResult] {
  await withTaskGroup(of: ExtractedContentResult.self) { group in
    var active = 0
    var collected: [ExtractedContentResult] = []

    for request in requests {
      if active >= 8, let result = await group.next() {
        collected.append(result)
        active -= 1
      }
      let isAdded = group.addTaskUnlessCancelled {
        do throws(ExtractedContentFailure) {
          return (request.entryID, .success(try await client.fetchExtractedContent(from: request.url)))
        } catch {
          return (request.entryID, .failure(error))
        }
      }
      guard isAdded else { break }
      active += 1
    }

    for await result in group {
      collected.append(result)
    }

    return collected
  }
}

/// The summary log line is public, so it holds only the outcome names and the
/// counts.
nonisolated private struct ExtractedContentTally {
  private enum Outcome: String, CaseIterable {
    case fetched, http4xx, rateLimited, http5xx, httpOther, undecodable, noContent
    case transport, unreachable, cancelled
  }

  private var counts: [Outcome: Int] = [:]
  private var sent = 0
  private let due: Int

  init(due: Int) {
    self.due = due
  }

  mutating func add(_ results: [ExtractedContentResult]) {
    sent += results.count
    for item in results {
      counts[Self.outcome(of: item.result), default: 0] += 1
    }
  }

  var summary: String {
    let parts = Outcome.allCases.compactMap { outcome in
      counts[outcome].map { "\(outcome.rawValue) \($0)" }
    }
    return (parts + ["notSent \(due - sent)"]).joined(separator: ", ")
  }

  private static func outcome(of result: Result<String, ExtractedContentFailure>) -> Outcome {
    switch result {
    case .success: .fetched
    case .failure(.http(status: 429)): .rateLimited
    case .failure(.http(let status)) where (400...499).contains(status): .http4xx
    case .failure(.http(let status)) where (500...599).contains(status): .http5xx
    case .failure(.http): .httpOther
    case .failure(.undecodable): .undecodable
    case .failure(.noContent): .noContent
    case .failure(let failure) where failure.stopsBatch: .unreachable
    case .failure(.transport): .transport
    case .failure(.cancelled): .cancelled
    }
  }
}

// MARK: - SyncEngine

/// Orchestrates Feedbin sync. Every SwiftData write is delegated to
/// `DataWriter`; this type is `@MainActor @Observable` for progress and account
/// display only, and processes no data on MainActor.
@MainActor
@Observable
final class SyncEngine {
  /// `ContentView.body` must never read it: a phase change must not re-render
  /// the split view.
  private(set) var account: FeedbinAccountPhase

  /// Keeps `sync()` and `refetchHistory()` from overlapping: either acquires
  /// the flag at the start and releases it before returning.
  private(set) var isSyncing = false
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

  /// Call it only through the account methods, so the phase matches the store.
  let credentialStore: any FeedbinCredentialStore
  private let makeClient: @MainActor (FeedbinCredentials) -> any FeedbinClientProtocol
  // Engine-owned and never cancelled: an account read or save must finish and
  // set the phase even when the view that started it goes away.
  private var accountRead: Task<Void, Never>?
  private var accountSave: Task<Bool, any Error>?
  private var client: (any FeedbinClientProtocol)?
  private(set) var writer: DataWriter?
  /// Read-only companion to `writer`. Vended to the article list and sidebar,
  /// so their reads run on a separate actor and never queue behind a write.
  /// The caller owns it; the engine only holds the reference.
  private(set) var reader: DataReader?
  private var periodicSyncTask: Task<Void, Never>?
  private var backfillTask: Task<Void, Never>?
  private var extractedContentTask: Task<Void, Never>?
  private var extractedContentTaskID: UUID?
  @ObservationIgnored
  private var extractedContentRetry = ExtractedContentRetrySchedule()
  private var lastProgressUpdate: ContinuousClock.Instant = .now

  private static let pendingReadKey = "pendingReadIDsToSync"
  private static let extractedContentChunkSize = 64

  private var pendingReadIDsToSync: Set<Int> {
    get {
      Set(defaults.array(forKey: Self.pendingReadKey) as? [Int] ?? [])
    }
    set {
      defaults.set(Array(newValue), forKey: Self.pendingReadKey)
    }
  }

  @ObservationIgnored
  private var pendingReadsByWindow: [UUID: Set<Int>] = [:]
  @ObservationIgnored
  private var readIDsQueuedThisLaunch: Set<Int> = []

  /// A test passes an isolated `defaults` suite: the standard domain holds the
  /// owner's real sync state.
  init(
    defaults: UserDefaults = .standard,
    credentialStore: any FeedbinCredentialStore,
    account: FeedbinAccountPhase = .checking,
    makeClient: @escaping @MainActor (FeedbinCredentials) -> any FeedbinClientProtocol = {
      FeedbinClient(username: $0.username, password: $0.password)
    }
  ) {
    self.defaults = defaults
    self.credentialStore = credentialStore
    self.account = account
    self.makeClient = makeClient
  }

  /// Never reads the Keychain and never contacts Feedbin.
  static func preview(account: FeedbinAccountPhase = .unused) -> SyncEngine {
    SyncEngine(credentialStore: MemoryFeedbinCredentialStore(), account: account) { _ in InertFeedbinClient() }
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

  /// Bypasses the account phase: attach only an inert or fake client.
  func attachClient(_ client: any FeedbinClientProtocol) {
    self.client = client
  }

  // MARK: - Feedbin account

  /// Reads only in the `.checking` phase. A call during a read waits for it.
  func loadAccountAtLaunch() async {
    await readAccount(onlyFrom: .checking)
  }

  /// Reads only in the `.unreadable` phase. A call during a read waits for it.
  func retryAccount() async {
    await readAccount(onlyFrom: .unreadable)
  }

  /// Verifies the credentials with Feedbin before any Keychain write, and
  /// returns false when Feedbin rejects them. A network or Keychain failure
  /// throws. A call during a read or another save waits for it first.
  func saveAccount(username: String, password: String) async throws -> Bool {
    guard account != .unused else { return false }
    while true {
      if let accountRead {
        await accountRead.value
      } else if let accountSave {
        _ = try? await accountSave.value
      } else {
        break
      }
    }
    let credentials = FeedbinCredentials(username: username, password: password)
    let save = Task { () async throws -> Bool in
      defer { accountSave = nil }
      return try await replaceAccount(with: credentials)
    }
    accountSave = save
    return try await save.value
  }

  private func readAccount(onlyFrom phase: FeedbinAccountPhase) async {
    if let accountRead {
      await accountRead.value
      return
    }
    guard account == phase, accountSave == nil else { return }
    let read = Task {
      await resolveAccount()
      accountRead = nil
    }
    accountRead = read
    await read.value
  }

  private func resolveAccount() async {
    account = .checking
    do {
      guard let credentials = try await loadOrMigrateCredentials(), credentials.isComplete else {
        account = .noAccount
        return
      }
      client = makeClient(credentials)
      account = .signedIn(username: credentials.username)
    } catch {
      account = .unreadable
    }
  }

  /// Calls `loadLegacy()` only when `load()` returns nil, and never calls
  /// `remove()`. Never contacts Feedbin, so an offline launch signs in.
  /// Calls `removeLegacy()` only after the add succeeds: a failed add signs
  /// in from the legacy values and keeps them for the next launch.
  private func loadOrMigrateCredentials() async throws(KeychainError) -> FeedbinCredentials? {
    if let stored = try await credentialStore.load() { return stored }
    guard let legacy = try await credentialStore.loadLegacy(), legacy.isComplete else { return nil }
    do {
      try await credentialStore.add(legacy)
    } catch {
      return legacy
    }
    await credentialStore.removeLegacy()
    return legacy
  }

  /// Must remove before the add: an update would keep the access list of the
  /// old Keychain item.
  private func replaceAccount(with credentials: FeedbinCredentials) async throws -> Bool {
    let candidate = makeClient(credentials)
    guard try await candidate.verifyCredentials() else { return false }
    try await credentialStore.remove()
    do {
      try await credentialStore.add(credentials)
    } catch {
      // The remove completed, so no account is stored.
      stopPeriodicSync()
      client = nil
      account = .noAccount
      throw error
    }
    await credentialStore.removeLegacy()
    client = candidate
    account = .signedIn(username: credentials.username)
    return true
  }

  // MARK: - Read queue

  /// Queue entry IDs to push to Feedbin as read. Until a push succeeds,
  /// `DataWriter.updateReadState` keeps a queued ID read, and
  /// `applyQueuedReads()` writes a queued ID to the store as read at launch.
  /// Also record the IDs, so that `queueRecordedPendingReads()` does not queue
  /// them again.
  func queueReadIDs(_ ids: Set<Int>) {
    guard !ids.isEmpty else { return }
    pendingReadIDsToSync.formUnion(ids)
    readIDsQueuedThisLaunch.formUnion(ids)
  }

  /// Keep a copy of the pending reads of one window for the quit step. An
  /// empty set removes the copy. Do not remove a copy when its window closes:
  /// the quit step must also see the reads of a closed window.
  func recordPendingReads(_ ids: Set<Int>, forWindow window: UUID) {
    pendingReadsByWindow[window] = ids.isEmpty ? nil : ids
  }

  /// Add the pending reads of every window to the read queue, except the IDs
  /// that `queueReadIDs(_:)` queued earlier in this launch. A push can have
  /// sent those IDs already, and a second push would undo a later mark-unread
  /// on another device.
  func queueRecordedPendingReads() {
    // Keep this method synchronous:
    // `FeederAppDelegate.applicationWillTerminate(_:)` calls it.
    let ids = Set(pendingReadsByWindow.values.joined()).subtracting(readIDsQueuedThisLaunch)
    queueReadIDs(ids)
    logger.info("Quit: queued \(ids.count, privacy: .public) pending reads")
  }

  /// Write the queued reads to the store as read. It needs the attached
  /// writer, and it is safe to call more than once.
  func applyQueuedReads() async {
    guard let writer else { return }
    let ids = pendingReadIDsToSync
    if !ids.isEmpty {
      do {
        try await writer.markEntriesRead(feedbinEntryIDs: ids)
      } catch {
        logger.error("Launch: failed to apply queued reads: \(error.localizedDescription)")
        return
      }
    }
    logger.info("Launch: applied \(ids.count, privacy: .public) queued reads")
  }

  /// Push the queued read IDs to Feedbin. Only the pushed IDs leave the queue,
  /// and a failed push keeps all of them. A call while `isSyncing` is true does
  /// nothing, and the IDs stay queued for a later push, such as the next
  /// `sync()`.
  func pushPendingReads() async {
    guard !isSyncing else { return }
    await pushQueuedReads()
  }

  private func pushQueuedReads() async {
    let ids = pendingReadIDsToSync
    guard let client, !ids.isEmpty else { return }
    do {
      try await client.deleteUnreadEntries(Array(ids))
      // Subtract, never clear: an ID queued during the request is not pushed yet.
      pendingReadIDsToSync.subtract(ids)
    } catch {
      // Log only, and set no `lastError`: the IDs stay queued for the next push.
      logger.error("Failed to push read state: \(error.localizedDescription)")
    }
  }

  // MARK: - Sync

  /// Start periodic background sync using structured concurrency.
  func startPeriodicSync(interval: TimeInterval = 300) {
    stopPeriodicSync()
    periodicSyncTask = Task {
      await CredentialResidue.removeFromSharedCache()
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
    extractedContentTaskID = nil
  }

  /// Pull subscriptions and icons, then fetch entries since the last
  /// successful sync. On the first run `since` falls back to the keep-days
  /// cutoff, so the first call already covers the full window. In the
  /// `.unreadable` phase the call first reads the Keychain again, which can
  /// show the access dialog.
  func sync() async {
    if account == .unreadable { await retryAccount() }
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
      await pushQueuedReads()

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
      // Back-to-back persist intervals with no fetch gap between them show
      // coordinator saturation in a trace.
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

    let readStateFlips = try await writer.updateReadState(unreadIDs: unreadIDSet, queuedReadIDs: pendingReadIDsToSync)

    if totalNew > 0 || readStateFlips > 0 {
      logger.info("Entry fetch: \(totalNew) new + \(readStateFlips) read-state flips")
    }

    return totalNew + readStateFlips
  }

  // MARK: - Background: Extracted content fetching

  private func startExtractedContentFetch() {
    guard extractedContentTask == nil, let client, let writer else { return }
    let id = UUID()
    extractedContentTaskID = id
    extractedContentTask = Task(priority: .utility) {
      defer { finishExtractedContentFetch(id) }
      do {
        try await fetchDueExtractedContent(using: client, writer: writer)
      } catch {
        logger.error("Extracted content fetch failed: \(error.localizedDescription)")
      }
    }
  }

  private func finishExtractedContentFetch(_ id: UUID) {
    guard extractedContentTaskID == id else { return }
    extractedContentTask = nil
    extractedContentTaskID = nil
  }

  private func fetchDueExtractedContent(using client: any FeedbinClientProtocol, writer: DataWriter) async throws {
    let pending = try await writer.fetchExtractedContentRequests()
    guard !pending.isEmpty else { return }
    let now = Date()
    let due = pending.filter { extractedContentRetry.isDue($0.entryID, now: now) }
    let waiting = pending.count - due.count
    logger.info("Fetching extracted content for \(due.count, privacy: .public) entries (\(waiting, privacy: .public) wait for a retry)")

    var tally = ExtractedContentTally(due: due.count)
    defer { logger.info("Extracted content: \(tally.summary, privacy: .public)") }
    for start in stride(from: 0, to: due.count, by: Self.extractedContentChunkSize) {
      guard !Task.isCancelled else { return }
      let chunk = Array(due[start..<min(start + Self.extractedContentChunkSize, due.count)])
      let results = await fetchExtractedContentBatch(requests: chunk, using: client)
      tally.add(results)
      let recordedAt = Date()
      for item in results {
        extractedContentRetry.record(item.result.map { _ in }, for: item.entryID, now: recordedAt)
      }
      let fetched = results.compactMap { item in
        (try? item.result.get()).map { (entryID: item.entryID, content: $0) }
      }
      // Do not add a cancellation check before this write: a stopped batch
      // still writes the content that already arrived.
      if !fetched.isEmpty {
        try await writer.applyExtractedContent(results: fetched)
      }
      let stopsBatch = results.contains { item in
        guard case .failure(let failure) = item.result else { return false }
        return failure.stopsBatch
      }
      if stopsBatch { return }
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

  /// True while the engine holds a periodic sync, backfill, or content-fetch
  /// task. For tests only: production code must not branch on it.
  var hasScheduledSyncWork: Bool {
    periodicSyncTask != nil || backfillTask != nil || extractedContentTask != nil
  }
}
