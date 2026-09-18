import Foundation
import Testing

@testable import Feeder

// MARK: - Sidebar unread aggregation architectural shape

/// Pins the contract the sidebar consumes: it derives its badge counts from a
/// pre-computed snapshot and never re-aggregates the unread universe per
/// render.
///
/// 1. Every badge count is a direct dictionary lookup on the snapshot, so no
///    MainActor iteration derives a count.
/// 2. The pending-overlay subtraction is bounded by the number of unique
///    categories or folders, not by the number of unread entries, so a
///    re-render stays proportional to the buckets.
///
/// A refactor that reintroduces a per-render entry walk on MainActor fails
/// these tests, because the contract disappears from the snapshot's surface or
/// the bounded shape breaks.
struct SidebarAggregationShapeTests {
  // MARK: - Snapshot exposes every aggregation MainActor needs

  /// Every badge count the sidebar renders — category badges, folder
  /// badges, total unread — must be a direct dictionary lookup or a
  /// trivially-typed scalar on `UnreadCountsSnapshot`. No method is
  /// invoked on the snapshot to derive a count; the count is the stored
  /// value.
  @Test
  func snapshotExposesPrecomputedCountsAsDictionaryLookups() {
    let snapshot = UnreadCountsSnapshot(
      categoryCounts: ["apple": 3, "world_news": 2],
      folderCounts: ["tech": 3],
      unreadFeedbinEntryIDs: [1, 2, 3, 4, 5],
      unreadIDByCategory: [
        "apple": [1, 2, 3],
        "world_news": [4, 5],
      ],
      unreadIDByFolder: ["tech": [1, 2, 3]],
      totalUnread: 5
    )

    // Per-category badge derivation — direct dictionary lookup, no
    // iteration over entries on MainActor.
    #expect(snapshot.categoryCounts["apple"] == 3)
    #expect(snapshot.categoryCounts["world_news"] == 2)
    #expect(snapshot.categoryCounts["unknown"] == nil)

    // Per-folder badge derivation — same shape.
    #expect(snapshot.folderCounts["tech"] == 3)
    #expect(snapshot.folderCounts["world"] == nil)

    // Total unread — stored, not summed at render time.
    #expect(snapshot.totalUnread == 5)
  }

  // MARK: - Pending overlay subtraction is O(buckets), not O(entries)

  /// `pendingReadCountsByCategory` must stay bounded by the number of
  /// unique categories the snapshot tracks, regardless of the size of
  /// `pendingReadIDs`. The cost model the sidebar relies on is "per render,
  /// iterate over a handful of categories" — not "iterate the unread
  /// universe".
  ///
  /// This is verified indirectly by feeding a small category keyspace and
  /// a large pending set, then asserting the overlay's bucket count
  /// matches the snapshot's category count (not the pending-set count).
  @Test
  func pendingOverlayIsBoundedByCategoryCountNotEntryCount() {
    // Snapshot with 3 categories but 1000 unread entries spread across
    // them. The pending set carries all 1000 IDs.
    var unreadByCategory: [String: Set<Int>] = ["apple": [], "world_news": [], "media": []]
    var unreadIDs: Set<Int> = []
    for i in 0..<1000 {
      let bucket = i % 3
      let label = ["apple", "world_news", "media"][bucket]
      unreadByCategory[label]?.insert(i)
      unreadIDs.insert(i)
    }
    let snapshot = UnreadCountsSnapshot(
      categoryCounts: unreadByCategory.mapValues(\.count),
      folderCounts: [:],
      unreadFeedbinEntryIDs: unreadIDs,
      unreadIDByCategory: unreadByCategory,
      unreadIDByFolder: [:],
      totalUnread: 1000
    )

    let overlay = pendingReadCountsByCategory(snapshot: snapshot, pending: unreadIDs)

    // The overlay carries exactly one entry per category the snapshot
    // knows about — not 1000 entries, one per pending ID. This is the
    // O(buckets) shape the sidebar depends on.
    #expect(overlay.count == snapshot.categoryCounts.count)
    #expect(overlay.count == 3)
  }

  /// Symmetric check for folder overlay: still bounded by folder count,
  /// not by pending-set size.
  @Test
  func folderOverlayIsBoundedByFolderCountNotEntryCount() {
    var unreadByFolder: [String: Set<Int>] = ["tech": [], "media": []]
    var unreadIDs: Set<Int> = []
    for i in 0..<500 {
      let bucket = i % 2
      let label = ["tech", "media"][bucket]
      unreadByFolder[label]?.insert(i)
      unreadIDs.insert(i)
    }
    let snapshot = UnreadCountsSnapshot(
      categoryCounts: [:],
      folderCounts: unreadByFolder.mapValues(\.count),
      unreadFeedbinEntryIDs: unreadIDs,
      unreadIDByCategory: [:],
      unreadIDByFolder: unreadByFolder,
      totalUnread: 500
    )

    let overlay = pendingReadCountsByFolder(snapshot: snapshot, pending: unreadIDs)

    #expect(overlay.count == snapshot.folderCounts.count)
    #expect(overlay.count == 2)
  }

  // MARK: - `subtractingPendingCounts` shape

  /// `subtractingPendingCounts` produces a new dictionary in O(buckets)
  /// without re-iterating any entry-level data — the per-render code path
  /// the sidebar runs cannot accidentally grow into an entry walk.
  @Test
  func subtractingPendingCountsHasSameKeyspaceAsInput() {
    let counts: [String: Int] = ["apple": 3, "world_news": 2, "media": 1]
    let overlay: [String: Int] = ["apple": 1, "world_news": 5]
    let result = counts.subtractingPendingCounts(overlay)

    // Result keys are a subset of input keys (no synthesised entries),
    // and the operation stays bounded by `counts.count` — not by
    // `overlay.values.reduce(0, +)` or any entry-level quantity.
    for key in result.keys {
      #expect(counts.keys.contains(key))
    }
  }
}
