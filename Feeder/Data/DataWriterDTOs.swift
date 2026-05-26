import Foundation
import SwiftData

// MARK: - Sendable DTOs for crossing actor boundaries

/// Input data for classification — extracted from Entry on background actor, consumed by FM inference.
nonisolated struct ClassificationInput: Sendable {
  let entryID: Int
  let title: String
  let body: String
  let url: String
}

/// Classification result — produced by FM inference, applied to Entry on background actor.
nonisolated struct ClassificationResult: Sendable {
  let entryID: Int
  let categoryLabel: String
  let confidence: Double
}

/// Category definition — read from SwiftData, passed to classification as Sendable.
nonisolated struct CategoryDefinition: Sendable {
  let label: String
  let description: String
  let folderLabel: String?
  let keywords: [String]

  init(label: String, description: String, folderLabel: String? = nil, keywords: [String] = []) {
    self.label = label
    self.description = description
    self.folderLabel = folderLabel
    self.keywords = keywords
  }
}

/// One day-grouped section of the article list. Built off-MainActor by
/// `DataWriter.fetchEntrySections` and consumed by `EntryListView`.
/// Only carries lightweight identifiers — the view materializes Entry objects
/// per-row on MainActor via `modelContext.model(for:)` (lazy, only visible rows).
nonisolated struct EntryListSection: Sendable, Identifiable, Equatable {
  let id: Date  // start-of-day, used as ForEach identity
  let label: String
  let entryIDs: [PersistentIdentifier]
}

/// Result of `DataWriter.purgeEntriesOlderThan(_:)`. Reported to the caller for
/// logging the disk-retention cleanup pass. Purge is a pure runtime delete —
/// not a schema migration — so the outcome is intentionally small.
nonisolated struct PurgeOutcome: Sendable, Equatable {
  let purgedCount: Int
}

/// Cached aggregation over the classified-unread universe used by the sidebar
/// to render its badges. Computed off-MainActor by
/// `DataWriter.fetchUnreadCountsSnapshot()` so `ContentView.body` never pays
/// the cost of `@Query unreadEntries` materialization + per-row property
/// access — Time Profiler showed that path consuming 85% of body time at 33%
/// of total main-thread CPU. The dictionaries are read as direct lookups; the
/// ID sets back the optimistic-overlay subtraction in
/// `pendingReadCountsByCategory` / `pendingReadCountsByFolder` and the
/// mark-all-read fast path.
nonisolated struct UnreadCountsSnapshot: Sendable, Equatable {
  let categoryCounts: [String: Int]
  let folderCounts: [String: Int]
  let unreadFeedbinEntryIDs: Set<Int>
  let unreadIDByCategory: [String: Set<Int>]
  let unreadIDByFolder: [String: Set<Int>]
  let totalUnread: Int

  static let empty = UnreadCountsSnapshot(
    categoryCounts: [:],
    folderCounts: [:],
    unreadFeedbinEntryIDs: [],
    unreadIDByCategory: [:],
    unreadIDByFolder: [:],
    totalUnread: 0
  )
}
