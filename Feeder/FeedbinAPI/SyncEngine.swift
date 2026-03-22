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

/// Orchestrates Feedbin API sync. All SwiftData writes are delegated to DataWriter (background actor).
/// SyncEngine stays @MainActor @Observable only for progress UI — zero data processing on MainActor.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var isBackfilling = false
    private(set) var isFetchingContent = false
    private(set) var lastError: String?
    private(set) var syncProgress: String = ""
    private(set) var fetchedCount: Int = 0
    private(set) var totalToFetch: Int = 0

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

    /// Configure the sync engine with credentials and model container.
    /// DataWriter is created on a background thread to ensure it runs off MainActor.
    func configure(username: String, password: String, modelContainer: ModelContainer) {
        self.client = FeedbinClient(username: username, password: password)
        self.writer = DataWriter(modelContainer: modelContainer)
        logger.info("Configured sync engine. Last sync: \(self.lastSyncDate?.description ?? "never").")
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
            syncProgress = "Syncing feeds..."
            let subscriptions = try await client.fetchSubscriptions()
            logger.info("Fetched \(subscriptions.count) subscriptions")
            try await writer.syncFeeds(subscriptions)

            if lastSyncDate != nil {
                try await syncIncremental(using: client, writer: writer)
            } else {
                try await syncUnread(using: client, writer: writer)
            }

            let isFirstSync = lastSyncDate == nil
            lastSyncDate = Date()
            fetchedCount = 0
            totalToFetch = 0
            isSyncing = false

            startExtractedContentFetch()
            if isFirstSync {
                startBackfill()
            }

            logger.info("Primary sync complete")
        } catch {
            lastError = error.localizedDescription
            syncProgress = "Sync failed"
            logger.error("Sync failed: \(error.localizedDescription)")
            isSyncing = false
        }
    }

    // MARK: - Phase 1: Unread articles (streaming, newest first)

    private func syncUnread(using client: FeedbinClient, writer: DataWriter) async throws {
        syncProgress = "Fetching unread articles..."
        let unreadIDs = try await client.fetchUnreadEntryIDs()
        logger.info("Found \(unreadIDs.count) unread entries")

        guard !unreadIDs.isEmpty else {
            syncProgress = "No unread articles"
            return
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
            let recent = entries.filter { $0.createdAt >= cutoff }

            if recent.isEmpty && !entries.isEmpty {
                logger.info("Reached entries older than 7 days at batch \(batchStart / batchSize + 1), stopping")
                break
            }

            if !recent.isEmpty {
                let newCount = try await writer.persistEntries(recent, markAsRead: false)
                totalNew += newCount
                fetchedCount += newCount
                syncProgress = "Loaded \(totalNew) unread articles..."
                logger.info("Batch \(batchStart / batchSize + 1): \(newCount) new entries persisted (\(totalNew) total)")
            }
        }

        syncProgress = "Synced \(totalNew) unread articles"
        logger.info("Phase 1 complete: \(totalNew) unread entries persisted")
    }

    // MARK: - Incremental sync

    private func syncIncremental(using client: FeedbinClient, writer: DataWriter) async throws {
        syncProgress = "Checking unread state..."
        let unreadIDs = try await client.fetchUnreadEntryIDs()
        let unreadIDSet = Set(unreadIDs)

        let cutoff = Date().addingTimeInterval(-maxArticleAge)
        let sinceClamped = max(lastSyncDate ?? cutoff, cutoff)
        syncProgress = "Fetching new entries..."
        logger.info("Fetching entries since \(sinceClamped.description)")
        let entries = try await client.fetchAllEntries(since: sinceClamped)
        logger.info("Fetched \(entries.count) new entries")
        totalToFetch = entries.count

        if !entries.isEmpty {
            let newCount = try await writer.persistEntries(entries, unreadIDs: unreadIDSet)
            fetchedCount = newCount
            syncProgress = "Synced \(newCount) new entries"
            logger.info("Incremental sync: \(newCount) new entries")
        }

        try await writer.updateReadState(unreadIDs: unreadIDSet)
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

                // Fetch in parallel with concurrency limit of 8
                let results = await withTaskGroup(
                    of: (Int, String?).self,
                    returning: [(entryID: Int, content: String)].self
                ) { group in
                    var active = 0
                    var collected: [(entryID: Int, content: String)] = []

                    for request in requests {
                        if active >= 8 {
                            if let result = await group.next(),
                                let content = result.1
                            {
                                collected.append((entryID: result.0, content: content))
                            }
                            active -= 1
                        }
                        let reqClient = client
                        group.addTask {
                            let content = try? await reqClient.fetchExtractedContent(from: request.url)
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

    private func startBackfill() {
        backfillTask?.cancel()
        backfillTask = Task(priority: .utility) {
            guard let client, let writer else { return }

            isBackfilling = true
            syncProgress = "Loading recent history..."
            logger.info("Starting Phase 2: recent history backfill")

            do {
                let sevenDaysAgo = Date().addingTimeInterval(-maxArticleAge)
                var page = 1

                while !Task.isCancelled {
                    let result = try await client.fetchEntries(since: sevenDaysAgo, page: page)
                    if result.entries.isEmpty { break }

                    let newCount = try await writer.persistEntries(result.entries, markAsRead: true)
                    syncProgress = "History: page \(page) (\(newCount) new)"
                    logger.info("Backfill page \(page): \(result.entries.count) fetched, \(newCount) new")

                    if !result.hasNextPage { break }
                    page += 1
                }

                // Fetch extracted content for backfilled entries
                let requests = try await writer.fetchExtractedContentRequests()
                if !requests.isEmpty {
                    let results = await withTaskGroup(
                        of: (Int, String?).self,
                        returning: [(entryID: Int, content: String)].self
                    ) { group in
                        var collected: [(entryID: Int, content: String)] = []
                        for request in requests {
                            let reqClient = client
                            group.addTask {
                                let content = try? await reqClient.fetchExtractedContent(from: request.url)
                                return (request.entryID, content?.content)
                            }
                        }
                        for await result in group {
                            if let content = result.1 {
                                collected.append((entryID: result.0, content: content))
                            }
                        }
                        return collected
                    }
                    if !results.isEmpty {
                        try await writer.applyExtractedContent(results: results)
                    }
                }

                syncProgress = ""
                logger.info("Phase 2 backfill complete (\(page) pages)")
            } catch {
                logger.error("Backfill failed: \(error.localizedDescription)")
                syncProgress = ""
            }

            isBackfilling = false
        }
    }
}
