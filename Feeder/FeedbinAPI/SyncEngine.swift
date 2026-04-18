import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.feeder.app", category: "SyncEngine")

/// Maximum age for articles in days. Configurable via Settings → Sync.
/// Anything older than this is never fetched or persisted, and existing older articles are purged.
nonisolated var articleKeepDays: Int {
  let stored = UserDefaults.standard.integer(forKey: "article_keep_days")
  return stored > 0 ? stored : 7
}

nonisolated var maxArticleAge: TimeInterval {
  TimeInterval(articleKeepDays) * 24 * 60 * 60
}

/// Fixed 30-day ceiling for disk purge — the maximum value the keepDays picker offers.
nonisolated let maxRetentionAge: TimeInterval = 30 * 24 * 60 * 60

/// Current cutoff date based on keepDays. Articles older than this are hidden from UI.
nonisolated func articleCutoffDate() -> Date {
  Date().addingTimeInterval(-maxArticleAge)
}

/// Fetch extracted content for a batch of entries with a concurrency limit of 8.
nonisolated func fetchExtractedContentBatch(
  requests: [(entryID: Int, url: String)],
  using client: FeedbinClient
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

/// Orchestrates Feedbin API sync. All SwiftData writes are delegated to DataWriter (background actor).
/// SyncEngine stays @MainActor @Observable only for progress UI — zero data processing on MainActor.
@MainActor
@Observable
final class SyncEngine {
  private(set) var isSyncing = false
  private(set) var isFetchingContent = false
  private(set) var lastError: String?

  private(set) var fetchedCount: Int = 0
  private(set) var totalToFetch: Int = 0

  /// Number of new entries persisted during the most recent `sync()` call.
  /// Used by `ContentView` to decide whether to refresh the article list — a
  /// sync that fetched nothing new should not rebuild the off-MainActor
  /// `EntryListSection` snapshot, because the underlying data is unchanged.
  private(set) var lastSyncNewEntryCount: Int = 0

  /// Reactive cutoff date for @Query filtering. Updated when keepDays changes.
  private(set) var queryCutoffDate: Date = articleCutoffDate()

  /// Recalculate article cutoff from current keepDays setting.
  func refreshArticleCutoff() {
    queryCutoffDate = articleCutoffDate()
  }

  /// Last sync date — persisted to UserDefaults so incremental sync works across app restarts.
  private(set) var lastSyncDate: Date? {
    get { UserDefaults.standard.object(forKey: "lastSyncDate") as? Date }
    set { UserDefaults.standard.set(newValue, forKey: "lastSyncDate") }
  }

  private var client: FeedbinClient?
  private(set) var writer: DataWriter?
  private var periodicSyncTask: Task<Void, Never>?
  private var backfillTask: Task<Void, Never>?
  private var extractedContentTask: Task<Void, Never>?
  private var lastProgressUpdate: ContinuousClock.Instant = .now

  private static let pendingReadKey = "pendingReadIDsToSync"

  private var pendingReadIDsToSync: Set<Int> {
    get {
      Set(UserDefaults.standard.array(forKey: Self.pendingReadKey) as? [Int] ?? [])
    }
    set {
      UserDefaults.standard.set(Array(newValue), forKey: Self.pendingReadKey)
    }
  }

  /// Configure the sync engine with credentials and model container.
  /// DataWriter init is detached to a background task per CLAUDE.md ("DataWriter must init on a background thread").
  func configure(username: String, password: String, modelContainer: ModelContainer) async {
    self.client = FeedbinClient(username: username, password: password)
    await attachWriter(modelContainer: modelContainer)
    logger.info("Configured sync engine. Last sync: \(self.lastSyncDate?.description ?? "never").")
  }

  /// Attach a DataWriter without configuring credentials. Used by UI-test demo mode and any
  /// path that needs a writer without performing real sync. Also the shared helper used by
  /// `configure` so the detached-init pattern isn't duplicated.
  func attachWriter(modelContainer: ModelContainer) async {
    self.writer = await Task.detached(priority: .utility) {
      DataWriter(modelContainer: modelContainer)
    }.value
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
      lastError = error.localizedDescription
      return false
    }
  }

  /// Start periodic background sync using structured concurrency.
  func startPeriodicSync(interval: TimeInterval = 300) {
    stopPeriodicSync()
    periodicSyncTask = Task {
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

  /// Perform a phased sync.
  func sync() async {
    guard let client, let writer, !isSyncing else { return }

    isSyncing = true
    lastError = nil
    fetchedCount = 0
    totalToFetch = 0
    logger.info("Starting sync")

    do {
      // Sync subscriptions

      let subscriptions = try await client.fetchSubscriptions()
      logger.info("Fetched \(subscriptions.count) subscriptions")
      try await writer.syncFeeds(subscriptions)

      // Fetch and store favicon icons — only download icons that actually need updating
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

      let totalNew: Int
      if lastSyncDate != nil {
        totalNew = try await syncIncremental(using: client, writer: writer)
      } else {
        totalNew = try await syncUnread(using: client, writer: writer)
      }

      let isFirstSync = lastSyncDate == nil
      lastSyncDate = Date()
      fetchedCount = 0
      totalToFetch = 0
      lastSyncNewEntryCount = totalNew
      isSyncing = false

      startExtractedContentFetch()
      if isFirstSync {
        refetchHistory()
      }

      logger.info("Primary sync complete")
    } catch {
      lastError = error.localizedDescription

      logger.error("Sync failed: \(error.localizedDescription)")
      lastSyncNewEntryCount = 0
      isSyncing = false
    }
  }

  // MARK: - Phase 1: Unread articles (streaming, newest first)

  private func syncUnread(using client: FeedbinClient, writer: DataWriter) async throws -> Int {
    let unreadIDs = try await client.fetchUnreadEntryIDs()
    logger.info("Found \(unreadIDs.count) unread entries")

    guard !unreadIDs.isEmpty else {
      return 0
    }

    let sortedIDs = unreadIDs.sorted(by: >)
    let cutoff = Date().addingTimeInterval(-maxArticleAge)

    totalToFetch = sortedIDs.count
    fetchedCount = 0
    var totalNew = 0
    let batchSize = 100

    for batchStart in stride(from: 0, to: sortedIDs.count, by: batchSize) {
      let batchEnd = min(batchStart + batchSize, sortedIDs.count)
      let batchIDs = Array(sortedIDs[batchStart..<batchEnd])

      let entries = try await client.fetchEntriesByIDs(batchIDs)
      let now = ContinuousClock.now
      if now - lastProgressUpdate >= .milliseconds(200) || batchEnd == sortedIDs.count {
        fetchedCount = batchEnd
        lastProgressUpdate = now
      }
      let recent = entries.filter { $0.createdAt >= cutoff }

      if recent.isEmpty && !entries.isEmpty {
        logger.info("Reached entries older than 7 days at batch \(batchStart / batchSize + 1), stopping")
        break
      }

      if !recent.isEmpty {
        let newCount = try await writer.persistEntries(recent, markAsRead: false)
        totalNew += newCount

        logger.info("Batch \(batchStart / batchSize + 1): \(newCount) new entries persisted (\(totalNew) total)")
      }
    }

    logger.info("Phase 1 complete: \(totalNew) unread entries persisted")
    return totalNew
  }

  // MARK: - Incremental sync

  private func syncIncremental(using client: FeedbinClient, writer: DataWriter) async throws -> Int {
    await pushPendingReads()
    let unreadIDs = try await client.fetchUnreadEntryIDs()
    let unreadIDSet = Set(unreadIDs)

    let cutoff = Date().addingTimeInterval(-maxArticleAge)
    let sinceClamped = max(lastSyncDate ?? cutoff, cutoff)

    logger.info("Fetching entries since \(sinceClamped.description)")

    var totalNew = 0
    var totalFetched = 0
    for try await page in client.fetchAllEntryPages(since: sinceClamped) {
      if let total = page.totalCount { totalToFetch = total }
      let newCount = try await writer.persistEntries(page.entries, unreadIDs: unreadIDSet)
      totalNew += newCount
      totalFetched += page.entries.count
      let now = ContinuousClock.now
      if now - lastProgressUpdate >= .milliseconds(200) {
        fetchedCount = totalFetched
        lastProgressUpdate = now
      }
      logger.info("Incremental page: \(page.entries.count) entries (\(totalFetched) total)")
    }
    fetchedCount = totalFetched

    if totalNew > 0 {
      logger.info("Incremental sync: \(totalNew) new entries")
    }

    try await writer.updateReadState(unreadIDs: unreadIDSet)
    return totalNew
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

  // MARK: - Background: Recent history backfill

  func refetchHistory() {
    backfillTask?.cancel()
    backfillTask = Task(priority: .utility) {
      guard let client, let writer else { return }

      isSyncing = true
      fetchedCount = 0
      totalToFetch = 0
      // Reset on entry and assign on completion so the
      // `isSyncing = false` edge always reports this backfill's count, not a
      // stale value from the last primary `sync()`. `ContentView` reads this
      // in its `isSyncing` onChange gate; leaving it stale would either block
      // a legitimate refresh or trigger a bogus one.
      lastSyncNewEntryCount = 0
      var totalNew = 0

      logger.info("Starting Phase 2: recent history backfill")

      do {
        let sevenDaysAgo = Date().addingTimeInterval(-maxArticleAge)

        for try await page in client.fetchAllEntryPages(since: sevenDaysAgo) {
          if Task.isCancelled { break }
          if let total = page.totalCount { totalToFetch = total }
          let newCount = try await writer.persistEntries(page.entries, markAsRead: true)
          totalNew += newCount
          fetchedCount += page.entries.count

          logger.info("Backfill: \(page.entries.count) fetched, \(newCount) new (\(self.fetchedCount)/\(self.totalToFetch))")
        }

        // Fetch extracted content for backfilled entries
        let requests = try await writer.fetchExtractedContentRequests()
        if !requests.isEmpty {
          let results = await fetchExtractedContentBatch(requests: requests, using: client)
          if !results.isEmpty {
            try await writer.applyExtractedContent(results: results)
          }
        }

        logger.info("Phase 2 backfill complete (\(self.fetchedCount) entries)")
      } catch {
        logger.error("Backfill failed: \(error.localizedDescription)")
        totalNew = 0
      }

      lastSyncNewEntryCount = totalNew
      isSyncing = false
    }
  }
}
