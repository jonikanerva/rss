import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "SyncEngine")

/// Coordinates Feedbin API sync with local SwiftData persistence.
@MainActor
@Observable
final class SyncEngine {
    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?
    private(set) var syncProgress: String = ""

    private var client: FeedbinClient?
    private var modelContext: ModelContext?
    private var syncTimer: Timer?

    /// Configure the sync engine with credentials and model context.
    func configure(username: String, password: String, modelContext: ModelContext) {
        self.client = FeedbinClient(username: username, password: password)
        self.modelContext = modelContext
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

    /// Start periodic background sync.
    func startPeriodicSync(interval: TimeInterval = 300) { // 5 minutes default
        stopPeriodicSync()
        // Initial sync
        Task { await sync() }
        // Periodic timer
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.sync()
            }
        }
    }

    /// Stop periodic sync.
    func stopPeriodicSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    /// Perform a full sync: subscriptions + entries + extracted content.
    func sync() async {
        guard let client, let modelContext, !isSyncing else { return }

        isSyncing = true
        lastError = nil
        syncProgress = "Syncing subscriptions..."
        logger.info("Starting sync")

        do {
            // 1. Sync subscriptions (feeds)
            let subscriptions = try await client.fetchSubscriptions()
            syncProgress = "Synced \(subscriptions.count) feeds"
            logger.info("Fetched \(subscriptions.count) subscriptions")
            try syncFeeds(subscriptions, in: modelContext)

            // 2. Sync entries (incremental using lastSyncDate)
            syncProgress = "Fetching entries..."
            logger.info("Fetching entries (since: \(self.lastSyncDate?.description ?? "full sync"))")
            let entries = try await client.fetchAllEntries(since: lastSyncDate)
            syncProgress = "Fetched \(entries.count) entries, processing..."
            syncProgress = "Processing \(entries.count) entries..."
            logger.info("Fetched \(entries.count) total entries")
            let newEntryCount = try await syncEntries(entries, using: client, in: modelContext)

            // 3. Save and update timestamp
            try modelContext.save()
            lastSyncDate = Date()
            syncProgress = "Synced \(newEntryCount) new entries"
            logger.info("Sync complete: \(newEntryCount) new entries")
        } catch {
            lastError = error.localizedDescription
            syncProgress = "Sync failed"
            logger.error("Sync failed: \(error.localizedDescription)")
        }

        isSyncing = false
    }

    // MARK: - Private sync helpers

    private func syncFeeds(_ subscriptions: [FeedbinSubscription], in context: ModelContext) throws {
        // Build lookup of existing feeds by Feedbin subscription ID
        let descriptor = FetchDescriptor<Feed>()
        let existingFeeds = try context.fetch(descriptor)
        let existingByID = Dictionary(uniqueKeysWithValues: existingFeeds.map { ($0.feedbinSubscriptionID, $0) })

        for sub in subscriptions {
            if let existing = existingByID[sub.id] {
                // Update existing feed
                existing.title = sub.title
                existing.feedURL = sub.feedUrl
                existing.siteURL = sub.siteUrl
            } else {
                // Insert new feed
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

    private func syncEntries(
        _ entries: [FeedbinEntry],
        using client: FeedbinClient,
        in context: ModelContext
    ) async throws -> Int {
        guard !entries.isEmpty else { return 0 }

        // Get existing entry IDs for deduplication
        let entryIDs = entries.map(\.id)
        let existingDescriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { entry in
                entryIDs.contains(entry.feedbinEntryID)
            }
        )
        let existingEntries = try context.fetch(existingDescriptor)
        let existingIDs = Set(existingEntries.map(\.feedbinEntryID))

        // Build feed lookup by Feedbin feed ID
        let feedDescriptor = FetchDescriptor<Feed>()
        let feeds = try context.fetch(feedDescriptor)
        let feedsByFeedbinID = Dictionary(uniqueKeysWithValues: feeds.map { ($0.feedbinFeedID, $0) })

        var newCount = 0
        let totalEntries = entries.count
        var processed = 0
        var skippedDuplicates = 0
        var extractedCount = 0

        for feedbinEntry in entries {
            processed += 1

            // Skip duplicates
            if existingIDs.contains(feedbinEntry.id) {
                skippedDuplicates += 1
                continue
            }

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

            // Link to feed
            entry.feed = feedsByFeedbinID[feedbinEntry.feedId]

            // Fetch extracted content if available
            if let extractedURL = feedbinEntry.extractedContentUrl {
                if let extracted = try? await client.fetchExtractedContent(from: extractedURL) {
                    entry.extractedContent = extracted.content
                    extractedCount += 1
                }
            }

            context.insert(entry)
            newCount += 1

            // Update progress every 25 entries or on the last entry
            if processed % 25 == 0 || processed == totalEntries {
                syncProgress = "Processing entries \(processed)/\(totalEntries) (\(newCount) new, \(skippedDuplicates) skipped)"
                logger.info("Processing entries \(processed)/\(totalEntries): \(newCount) new, \(skippedDuplicates) duplicates, \(extractedCount) extracted")
            }
        }

        logger.info("Entry sync done: \(newCount) new, \(skippedDuplicates) duplicates, \(extractedCount) content extractions")
        return newCount
    }
}
