import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "SyncEngine")

/// Maximum age for articles. Anything older than this is never fetched or persisted.
private let maxArticleAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days

/// Strip HTML tags and decode entities to produce plain text.
nonisolated func stripHTMLToPlainText(_ html: String) -> String {
    guard !html.isEmpty else { return "" }
    var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "&amp;", with: "&")
    text = text.replacingOccurrences(of: "&lt;", with: "<")
    text = text.replacingOccurrences(of: "&gt;", with: ">")
    text = text.replacingOccurrences(of: "&quot;", with: "\"")
    text = text.replacingOccurrences(of: "&#39;", with: "'")
    text = text.replacingOccurrences(of: "&nbsp;", with: " ")
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Coordinates Feedbin API sync with local SwiftData persistence.
/// Sync is phased: unread articles first (fast, streaming), then recent history (background).
/// Extracted content and classification run as parallel background tasks.
/// Hard limit: never fetches or persists articles older than 7 days.
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
    private var modelContext: ModelContext?
    private var periodicSyncTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    private var extractedContentTask: Task<Void, Never>?

    /// Configure the sync engine with credentials and model context.
    func configure(username: String, password: String, modelContext: ModelContext) {
        self.client = FeedbinClient(username: username, password: password)
        self.modelContext = modelContext
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
            // Initial sync
            await sync()
            // Periodic loop
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
    /// - First sync (no lastSyncDate): Phase 1 (unread, streaming) then background tasks.
    /// - Subsequent syncs: incremental via `since` parameter.
    func sync() async {
        guard let client, let modelContext, !isSyncing else { return }

        isSyncing = true
        lastError = nil
        fetchedCount = 0
        totalToFetch = 0
        logger.info("Starting sync")

        do {
            // Always sync subscriptions first
            syncProgress = "Syncing feeds..."
            let subscriptions = try await client.fetchSubscriptions()
            logger.info("Fetched \(subscriptions.count) subscriptions")
            try syncFeeds(subscriptions, in: modelContext)

            if lastSyncDate != nil {
                try await syncIncremental(using: client, in: modelContext)
            } else {
                try await syncUnread(using: client, in: modelContext)
            }

            try modelContext.save()

            let isFirstSync = lastSyncDate == nil
            lastSyncDate = Date()
            fetchedCount = 0
            totalToFetch = 0
            isSyncing = false

            // Start background tasks in parallel
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

    private func syncUnread(using client: FeedbinClient, in context: ModelContext) async throws {
        syncProgress = "Fetching unread articles..."
        let unreadIDs = try await client.fetchUnreadEntryIDs()
        logger.info("Found \(unreadIDs.count) unread entries")

        guard !unreadIDs.isEmpty else {
            syncProgress = "No unread articles"
            return
        }

        // Sort descending — higher Feedbin IDs are newer entries
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

            // If no recent entries in this batch, we've passed the 7-day window — stop
            if recent.isEmpty && !entries.isEmpty {
                logger.info("Reached entries older than 7 days at batch \(batchStart / batchSize + 1), stopping")
                break
            }

            if !recent.isEmpty {
                let newCount = try persistEntries(recent, markAsRead: false, in: context)
                totalNew += newCount
                fetchedCount += newCount
                try context.save()
                syncProgress = "Loaded \(totalNew) unread articles..."
                logger.info("Batch \(batchStart / batchSize + 1): \(newCount) new entries persisted (\(totalNew) total)")
            }
        }

        syncProgress = "Synced \(totalNew) unread articles"
        logger.info("Phase 1 complete: \(totalNew) unread entries persisted")
    }

    // MARK: - Incremental sync (subsequent syncs)

    private func syncIncremental(using client: FeedbinClient, in context: ModelContext) async throws {
        // Fetch unread IDs to update read state
        syncProgress = "Checking unread state..."
        let unreadIDs = try await client.fetchUnreadEntryIDs()
        let unreadIDSet = Set(unreadIDs)

        // Fetch new entries since last sync, but never older than 7 days
        let cutoff = Date().addingTimeInterval(-maxArticleAge)
        let sinceClamped = max(lastSyncDate ?? cutoff, cutoff)
        syncProgress = "Fetching new entries..."
        logger.info("Fetching entries since \(sinceClamped.description)")
        let entries = try await client.fetchAllEntries(since: sinceClamped)
        logger.info("Fetched \(entries.count) new entries")
        totalToFetch = entries.count

        if !entries.isEmpty {
            let newCount = try persistEntries(entries, unreadIDs: unreadIDSet, in: context)
            fetchedCount = newCount
            syncProgress = "Synced \(newCount) new entries"
            logger.info("Incremental sync: \(newCount) new entries")
        }

        // Update read state for existing entries
        try updateReadState(unreadIDs: unreadIDSet, in: context)
    }

    // MARK: - Background: Extracted content fetching

    private func startExtractedContentFetch() {
        extractedContentTask?.cancel()
        extractedContentTask = Task(priority: .utility) {
            guard let client, let modelContext else { return }

            isFetchingContent = true
            logger.info("Starting background extracted content fetch")

            do {
                try await fetchExtractedContentParallel(in: modelContext, using: client)
                try modelContext.save()
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
            guard let client, let modelContext else { return }

            isBackfilling = true
            syncProgress = "Loading recent history..."
            logger.info("Starting Phase 2: recent history backfill")

            do {
                let sevenDaysAgo = Date().addingTimeInterval(-maxArticleAge)
                var page = 1

                while !Task.isCancelled {
                    let result = try await client.fetchEntries(since: sevenDaysAgo, page: page)
                    if result.entries.isEmpty { break }

                    let newCount = try persistEntries(result.entries, markAsRead: true, in: modelContext)
                    syncProgress = "History: page \(page) (\(newCount) new)"
                    logger.info("Backfill page \(page): \(result.entries.count) fetched, \(newCount) new")

                    try modelContext.save()

                    if !result.hasNextPage { break }
                    page += 1
                }

                // Fetch extracted content for backfilled entries
                try await fetchExtractedContentParallel(in: modelContext, using: client)
                try modelContext.save()

                syncProgress = ""
                logger.info("Phase 2 backfill complete (\(page) pages)")
            } catch {
                logger.error("Backfill failed: \(error.localizedDescription)")
                syncProgress = ""
            }

            isBackfilling = false
        }
    }

    // MARK: - Parallel extracted content fetching

    private func fetchExtractedContentParallel(
        in context: ModelContext,
        using client: FeedbinClient
    ) async throws {
        let descriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entry.extractedContentURL != nil && entry.extractedContent == nil
            }
        )
        let entriesNeedingContent = try context.fetch(descriptor)
        guard !entriesNeedingContent.isEmpty else { return }

        logger.info("Fetching extracted content for \(entriesNeedingContent.count) entries (parallel)")

        // Collect URLs before entering TaskGroup (Entry is not Sendable)
        let contentRequests: [(entryID: Int, url: String)] = entriesNeedingContent.compactMap { entry in
            guard let url = entry.extractedContentURL else { return nil }
            return (entryID: entry.feedbinEntryID, url: url)
        }

        // Fetch in parallel with concurrency limit of 8
        let unsafeClient = client
        let results = await withTaskGroup(
            of: (Int, String?).self,
            returning: [(Int, String?)].self
        ) { group in
            var active = 0
            var collected: [(Int, String?)] = []

            for request in contentRequests {
                if active >= 8 {
                    if let result = await group.next() {
                        collected.append(result)
                        active -= 1
                    }
                }
                group.addTask {
                    let content = try? await unsafeClient.fetchExtractedContent(from: request.url)
                    return (request.entryID, content?.content)
                }
                active += 1
            }

            for await result in group {
                collected.append(result)
            }

            return collected
        }

        // Apply results back to entries on MainActor
        let resultsByID = Dictionary(uniqueKeysWithValues: results.compactMap { id, content -> (Int, String)? in
            guard let content else { return nil }
            return (id, content)
        })

        var extractedCount = 0
        for entry in entriesNeedingContent {
            if let content = resultsByID[entry.feedbinEntryID] {
                entry.extractedContent = content
                entry.plainText = stripHTMLToPlainText(content)
                extractedCount += 1
            }
        }

        logger.info("Extracted content fetched: \(extractedCount)/\(entriesNeedingContent.count)")
    }

    // MARK: - Persistence helpers

    private func syncFeeds(_ subscriptions: [FeedbinSubscription], in context: ModelContext) throws {
        let descriptor = FetchDescriptor<Feed>()
        let existingFeeds = try context.fetch(descriptor)
        let existingByID = Dictionary(uniqueKeysWithValues: existingFeeds.map { ($0.feedbinSubscriptionID, $0) })

        for sub in subscriptions {
            if let existing = existingByID[sub.id] {
                existing.title = sub.title
                existing.feedURL = sub.feedUrl
                existing.siteURL = sub.siteUrl
            } else {
                let feed = Feed(
                    feedbinSubscriptionID: sub.id,
                    feedbinFeedID: sub.feedId,
                    title: sub.title,
                    feedURL: sub.feedUrl,
                    siteURL: sub.siteUrl,
                    createdAt: sub.createdAt
                )
                context.insert(feed)
            }
        }
    }

    /// Persist entries with explicit read state. Returns count of new entries inserted.
    private func persistEntries(
        _ entries: [FeedbinEntry],
        markAsRead: Bool,
        in context: ModelContext
    ) throws -> Int {
        guard !entries.isEmpty else { return 0 }

        let entryIDs = entries.map(\.id)
        let existingDescriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entryIDs.contains(entry.feedbinEntryID)
            }
        )
        let existingEntries = try context.fetch(existingDescriptor)
        let existingIDs = Set(existingEntries.map(\.feedbinEntryID))

        let feedDescriptor = FetchDescriptor<Feed>()
        let feeds = try context.fetch(feedDescriptor)
        let feedsByFeedbinID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.feedbinFeedID, $0) })

        var newCount = 0
        for feedbinEntry in entries {
            if existingIDs.contains(feedbinEntry.id) { continue }

            let entry = Entry(
                feedbinEntryID: feedbinEntry.id,
                title: feedbinEntry.title,
                author: feedbinEntry.author,
                url: feedbinEntry.url,
                content: feedbinEntry.content,
                summary: feedbinEntry.summary,
                extractedContentURL: feedbinEntry.extractedContentUrl,
                publishedAt: feedbinEntry.published,
                createdAt: feedbinEntry.createdAt
            )
            entry.feed = feedsByFeedbinID[feedbinEntry.feedId]
            entry.isRead = markAsRead
            entry.plainText = stripHTMLToPlainText(entry.bestHTML)
            context.insert(entry)
            newCount += 1
        }

        return newCount
    }

    /// Persist entries with read state determined by unread ID set.
    private func persistEntries(
        _ entries: [FeedbinEntry],
        unreadIDs: Set<Int>,
        in context: ModelContext
    ) throws -> Int {
        guard !entries.isEmpty else { return 0 }

        let entryIDs = entries.map(\.id)
        let existingDescriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entryIDs.contains(entry.feedbinEntryID)
            }
        )
        let existingEntries = try context.fetch(existingDescriptor)
        let existingIDs = Set(existingEntries.map(\.feedbinEntryID))

        let feedDescriptor = FetchDescriptor<Feed>()
        let feeds = try context.fetch(feedDescriptor)
        let feedsByFeedbinID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.feedbinFeedID, $0) })

        var newCount = 0
        for feedbinEntry in entries {
            if existingIDs.contains(feedbinEntry.id) { continue }

            let entry = Entry(
                feedbinEntryID: feedbinEntry.id,
                title: feedbinEntry.title,
                author: feedbinEntry.author,
                url: feedbinEntry.url,
                content: feedbinEntry.content,
                summary: feedbinEntry.summary,
                extractedContentURL: feedbinEntry.extractedContentUrl,
                publishedAt: feedbinEntry.published,
                createdAt: feedbinEntry.createdAt
            )
            entry.feed = feedsByFeedbinID[feedbinEntry.feedId]
            entry.isRead = !unreadIDs.contains(feedbinEntry.id)
            entry.plainText = stripHTMLToPlainText(entry.bestHTML)
            context.insert(entry)
            newCount += 1
        }

        return newCount
    }

    /// Update read state for existing entries based on Feedbin unread IDs.
    private func updateReadState(unreadIDs: Set<Int>, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<Entry>()
        let allEntries = try context.fetch(descriptor)

        var updatedCount = 0
        for entry in allEntries {
            let shouldBeRead = !unreadIDs.contains(entry.feedbinEntryID)
            if entry.isRead != shouldBeRead {
                entry.isRead = shouldBeRead
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            logger.info("Updated read state for \(updatedCount) entries")
        }
    }
}
