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

/// One rendered article-list row — a value snapshot of COMMITTED store state,
/// projected off-MainActor by `DataReader.projectEntryRow(_:)` (issue #148).
/// `EntryRowView` renders from this DTO alone: no `modelContext.model(for:)`,
/// no `entry.feed` relationship fault, no per-row store access on MainActor.
///
/// **Freshness contract (replaces the retired "no volatile scalar" rule).**
/// Rows deliberately carry volatile scalars (`isRead`, `title`, …): a row is a
/// snapshot of the last committed fetch, and freshness is bounded by the bump
/// pipeline — mutation paths bump `entryRefreshVersion` immediately, mid-flight
/// drains land within ≤ 1 s idle / ≤ 4 s selection dwell, and remote read-state
/// flips land on the sync-edge tick. The optimistic `pendingReadIDs` overlay
/// dims a row the moment the user opens it and is RETAINED until a refetched
/// source confirms the committed `isRead == true` (two-sided prune,
/// `retainedPendingReadIDs`), so no frame renders stale-unread regardless of
/// fetch landing order. `@Model` objects still never cross the actor boundary
/// (`STACK.md § 0`); the projection reads only the columns listed in
/// `fetchEntrySections`' `propertiesToFetch` plus the prefetched `feed`.
///
/// FULL-content `Equatable` / `Hashable` (synthesized over every stored field)
/// is load-bearing: content equality IS the row re-render mechanism — a
/// refetched row with any changed field compares non-equal and SwiftUI re-diffs
/// it. Do not shortcut either conformance to identity-only.
nonisolated struct EntryRowDTO: Sendable, Equatable, Hashable, Identifiable {
  let persistentID: PersistentIdentifier
  let feedbinEntryID: Int
  let title: String?
  let formattedPublishedTime: String
  let displayDomain: String?
  let excerpt: String
  let isRead: Bool
  /// Grouping input for `groupRowsByDay` only — never rendered (`STACK.md
  /// § 10`: user-facing time comes from the pre-computed display fields).
  let publishedAt: Date
  /// Favicon key — `feed.feedbinFeedID`, resolved once off-main from the
  /// prefetched relationship; nil when the entry has no feed.
  let feedFeedbinID: Int?
  /// Fallback initial for `FaviconView` when no favicon image exists: first
  /// letter of the feed title, uppercased; "?" when the feed is nil.
  let feedInitial: String

  var id: PersistentIdentifier { persistentID }
}

/// One day-grouped section of the article list. Built off-MainActor by
/// `DataReader.fetchEntrySections` and rendered directly by `EntryListView` —
/// the rows are complete `EntryRowDTO` snapshots (issue #148), so the view
/// layer performs zero store access. Freshness contract: see `EntryRowDTO`.
nonisolated struct EntryListSection: Sendable, Identifiable, Equatable {
  let id: Date  // start-of-day, used as ForEach identity
  let label: String
  let rows: [EntryRowDTO]
}

/// Background-fetched article list payload: the day-grouped row sections plus
/// three pre-flattened aggregates the MainActor consumes without walking the
/// row set again (each MainActor allocation eats into the 8.3 ms ProMotion
/// frame budget, `STACK.md` § Performance budgets):
/// - `allEntryIDs` — the `VisibleEntriesKey` preference ids (Tab-into-list,
///   anchor restore);
/// - `distinctFeedIDs` — the favicon keys `FaviconStore.ensureLoaded` warms
///   after each reload;
/// - `renderedUnreadFeedbinEntryIDs` — the rendered-unread side of the
///   two-sided `pendingReadIDs` retention prune (`retainedPendingReadIDs`).
///
/// `PersistentIdentifier` conforms to `Sendable`
/// (`developer.apple.com/documentation/swiftdata/persistentidentifier`), so the
/// payload crosses the actor boundary cleanly.
nonisolated struct EntryListFetchResult: Sendable, Equatable {
  let sections: [EntryListSection]
  let allEntryIDs: [PersistentIdentifier]
  let distinctFeedIDs: Set<Int>
  let renderedUnreadFeedbinEntryIDs: Set<Int>

  static let empty = EntryListFetchResult(
    sections: [], allEntryIDs: [], distinctFeedIDs: [], renderedUnreadFeedbinEntryIDs: [])
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
