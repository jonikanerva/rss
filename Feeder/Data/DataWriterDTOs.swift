import Foundation
import SwiftData

// MARK: - Sendable DTOs for crossing actor boundaries

/// Classification input, extracted from an `Entry` on a background actor.
nonisolated struct ClassificationInput: Sendable {
  let entryID: Int
  let title: String
  let body: String
  let url: String
}

/// Classification result, applied to an `Entry` on a background actor.
nonisolated struct ClassificationResult: Sendable {
  let entryID: Int
  let categoryLabel: String
  let confidence: Double?
}

/// Category definition, passed to classification as a `Sendable` value.
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

/// One rendered article-list row: a value snapshot of committed store state,
/// projected off MainActor. `EntryRowView` renders from this DTO alone, with no
/// `modelContext.model(for:)`, no relationship fault, and no per-row store
/// access on MainActor.
///
/// A row carries volatile scalars such as `isRead` on purpose. It is a snapshot
/// of the last committed fetch, and freshness is bounded by the refresh-bump
/// pipeline in `ContentView`. The optimistic `pendingReadIDs` overlay dims a row
/// as soon as the user opens it and is retained until a refetched source
/// confirms the committed state, so no frame renders stale-unread whatever
/// order the fetches land in.
///
/// The full-content `Equatable` and `Hashable` conformances are load-bearing:
/// content equality is the row re-render mechanism. Do not shortcut either one
/// to identity.
nonisolated struct EntryRowDTO: Sendable, Equatable, Hashable, Identifiable {
  let persistentID: PersistentIdentifier
  let feedbinEntryID: Int
  let title: String?
  let formattedPublishedTime: String
  /// Display domain of the entry's feed, or `nil` when the entry has no
  /// domain. The projection maps the stored empty string (`extractDomain` of
  /// a URL without a host) to `nil`, so `nil` means "no domain" everywhere.
  let displayDomain: String?
  let excerpt: String
  let isRead: Bool
  /// Grouping input for `groupRowsByDay` only. Never rendered — user-facing
  /// time comes from the pre-computed display fields (`STACK.md § 10`).
  let publishedAt: Date
  /// Favicon key, resolved once off-main from the prefetched relationship.
  /// `nil` when the entry has no feed.
  let feedFeedbinID: Int?
  /// Fallback initial when no favicon image exists: the feed title's first
  /// letter, uppercased, or "?" when the feed is `nil`.
  let feedInitial: String

  var id: PersistentIdentifier { persistentID }
}

/// One day-grouped section of the article list, built off MainActor. Its rows
/// are complete `EntryRowDTO` snapshots, so the view layer performs no store
/// access. For the freshness contract, see `EntryRowDTO`.
nonisolated struct EntryListSection: Sendable, Identifiable, Equatable {
  let id: Date  // start-of-day, used as ForEach identity
  let label: String
  let rows: [EntryRowDTO]
}

/// Keyset cursor into the canonical article-list order: the `(publishedAt,
/// feedbinEntryID)` sort key of a loaded row. Always derived from the applied
/// sections, never stored. The loaded window is defined entirely by its bottom
/// edge, the cursor of the last loaded row.
///
/// Cursor keys are stable only under the immutability invariant on
/// `DataWriter.persistEntries`, and keyset pages tile exactly only while that
/// invariant holds.
nonisolated struct EntryListCursor: Sendable, Equatable {
  let publishedAt: Date
  let feedbinEntryID: Int
}

/// Which slice of the canonical order `fetchEntrySections` returns. The three
/// modes share one eligibility predicate and one sort, and differ only in the
/// keyset clause:
/// - `firstPage(limit:)` — the top `limit` rows, fetched as an `after` from a
///   top sentinel cursor so the page and its appends tile by construction. The
///   limit grows past the request only to keep a pinned row reachable.
/// - `atOrAbove(cursor)` — every row at or above the cursor, replacing the
///   loaded window in one snapshot. Bounded by how far the user has grown the
///   window, not by the category size.
/// - `after(cursor, limit:)` — the next `limit` rows strictly below the cursor.
nonisolated enum EntryListWindow: Sendable, Equatable {
  case firstPage(limit: Int)
  case atOrAbove(EntryListCursor)
  case after(EntryListCursor, limit: Int)
}

/// Background-fetched article-list payload: the day-grouped sections plus three
/// aggregates flattened by the reader, so MainActor never walks the row set
/// again inside the frame budget (`STACK.md § 4`).
///
/// `hasMore` is exact. For `firstPage` and `after` the reader fetches one row
/// past the limit and drops it; for `atOrAbove` it probes with a single
/// one-row fetch below the window. `true` means the store holds at least one
/// eligible row below the returned window.
nonisolated struct EntryListFetchResult: Sendable, Equatable {
  let sections: [EntryListSection]
  let allEntryIDs: [PersistentIdentifier]
  let distinctFeedIDs: Set<Int>
  let renderedUnreadFeedbinEntryIDs: Set<Int>
  let hasMore: Bool

  static let empty = EntryListFetchResult(
    sections: [], allEntryIDs: [], distinctFeedIDs: [], renderedUnreadFeedbinEntryIDs: [],
    hasMore: false)
}

/// Result of `DataWriter.purgeEntriesOlderThan(_:)`, reported so the caller can
/// log the retention cleanup.
nonisolated struct PurgeOutcome: Sendable, Equatable {
  let purgedCount: Int
}

/// Result of `DataWriter.removeCategoryAndReassignArticles(_:to:)`: how many
/// entries moved, and the new folder label. The deletion is implicit — when
/// this value returns, the source category is gone from the store.
nonisolated struct RecategorizeOutcome: Sendable, Equatable {
  let reassignedCount: Int
  let targetFolderLabel: String
}

/// Errors thrown by the confirm-and-reassign category writes. Typed, so the UI
/// routes each case to its own alert without matching on
/// `localizedDescription`.
nonisolated enum CategoryReassignError: Error, Sendable, Equatable, LocalizedError {
  /// The source category label does not resolve to a row in the store.
  case sourceMissing
  /// The target category label does not resolve to a row in the store.
  case targetMissing
  /// Source and target labels are equal, which would delete the category the
  /// caller asked to keep the articles in.
  case sourceEqualsTarget
  /// The source category is system-owned and must not be deleted.
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

/// Cached aggregation over the classified-unread universe behind the sidebar
/// badges, computed off MainActor so `body` never materialises the unread rows.
/// The dictionaries are read as direct lookups; the ID sets back the
/// optimistic-overlay subtraction and the mark-all-read fast path.
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
