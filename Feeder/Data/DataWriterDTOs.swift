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
/// `DataReader.fetchEntrySections` and consumed by `EntryListView`.
/// Only carries lightweight identifiers — the view materializes Entry objects
/// per-row on MainActor via `modelContext.model(for:)` (lazy, only visible rows).
nonisolated struct EntryListSection: Sendable, Identifiable, Equatable {
  let id: Date  // start-of-day, used as ForEach identity
  let label: String
  let entryIDs: [PersistentIdentifier]
}

/// Background-fetched article list payload: the day-grouped sections plus the
/// pre-flattened entry-ID list the MainActor's `VisibleEntryIDsKey` preference
/// needs. Computing the flat list off-MainActor (the writer already walks every
/// entry once for `groupEntriesByDay`) saves the view from a per-reload
/// `result.flatMap(\.entryIDs)` allocation against the entire row set —
/// meaningful for large categories ("uncategorized" with thousands of IDs)
/// where each MainActor allocation eats into the 8.3 ms ProMotion frame budget
/// (`STACK.md` § Performance budgets).
///
/// `PersistentIdentifier` conforms to `Sendable`
/// (`developer.apple.com/documentation/swiftdata/persistentidentifier`), so the
/// flattened array crosses the actor boundary cleanly.
nonisolated struct EntryListFetchResult: Sendable, Equatable {
  let sections: [EntryListSection]
  let allEntryIDs: [PersistentIdentifier]

  static let empty = EntryListFetchResult(sections: [], allEntryIDs: [])
}

/// Result of `DataWriter.purgeEntriesOlderThan(_:)`. Reported to the caller for
/// logging the disk-retention cleanup pass. Purge is a pure runtime delete —
/// not a schema migration — so the outcome is intentionally small.
nonisolated struct PurgeOutcome: Sendable, Equatable {
  let purgedCount: Int
}

/// Result of `DataWriter.removeCategoryAndReassignArticles(_:to:)`.
/// Carries the number of entries whose `primaryCategory` (and possibly
/// `primaryFolder`) was reassigned to the target category, plus the new folder
/// label so the caller can log the user-facing summary. The category-deletion
/// step is implicit — when this DTO returns successfully the source category
/// is gone from the store.
nonisolated struct RecategorizeOutcome: Sendable, Equatable {
  let reassignedCount: Int
  let targetFolderLabel: String
}

/// Errors thrown by category-management writes that participate in the
/// confirm-and-reassign flow surfaced by `CategoryManagementView`.
/// Typed so the UI can route each case to a precise alert message without
/// string-matching `localizedDescription`.
nonisolated enum CategoryReassignError: Error, Sendable, Equatable, LocalizedError {
  /// The source category label does not resolve to a row in the store.
  case sourceMissing
  /// The target category label does not resolve to a row in the store.
  case targetMissing
  /// Source and target labels are equal — would delete the category the
  /// caller asked to keep articles in.
  case sourceEqualsTarget
  /// The source category is system-owned (e.g. `uncategorized`) and must
  /// not be deleted.
  case sourceIsSystem

  var errorDescription: String? {
    switch self {
    case .sourceMissing:
      return "The category you tried to remove no longer exists."
    case .targetMissing:
      return "The category you picked as the move target no longer exists."
    case .sourceEqualsTarget:
      return "You can't move articles into the same category you're removing."
    case .sourceIsSystem:
      return "Built-in categories can't be removed."
    }
  }
}

/// Cached aggregation over the classified-unread universe used by the sidebar
/// to render its badges. Computed off-MainActor by
/// `DataReader.fetchUnreadCountsSnapshot()` so `ContentView.body` never pays
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
