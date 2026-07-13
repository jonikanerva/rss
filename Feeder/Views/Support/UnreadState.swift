import Foundation
import SwiftData
import SwiftUI

// MARK: - Unread State (badge / overlay / refresh owner, issue #146 final fix)

/// Owner of the unread universe the panes render from: the cached sidebar
/// snapshot, the optimistic pending-read overlay, the article-list refresh
/// version, and the rendered-entries payload. Extracted from `ContentView`
/// `@State` so overlay / snapshot churn re-evaluates only the panes that
/// read it (`SidebarInner` badge math, `ContentPane` environment injection)
/// — never the `NavigationSplitView` shell. Injected via `.environment`
/// from `ContentView`'s `@State`; not a singleton.
@MainActor
@Observable
final class UnreadState {
  /// Cached aggregation over the classified-unread universe. Refreshed by
  /// `UnreadSnapshotRefreshTask` (in `SidebarInner`) whenever
  /// `refreshVersion` or the taxonomy structure changes — never re-fetched
  /// inside a body. Replaces the historical `@Query unreadEntries` that
  /// fired a full SQLite fetch during every body re-eval.
  private(set) var snapshot: UnreadCountsSnapshot = .empty
  /// Optimistic pending-read overlay: entry IDs the user has opened this
  /// session that haven't been confirmed read by a refetch yet.
  /// `EntryRowView` dims from it (via the `pendingReadIDs` environment
  /// value); the sidebar badge math subtracts it. Pruned ONLY by the
  /// two-sided criterion in `prune()`.
  private(set) var pendingReadIDs: Set<Int> = []
  /// Bumped whenever underlying article data may have changed — sync edge,
  /// classification drain, mark-read flush, mark-all-read, category/folder
  /// reorganisation. `EntryListView` keys its refresh `.task(id:)` on it;
  /// `SidebarInner` keys the snapshot refresh on it. Single point of
  /// accountability: every mutation path calls `noteDataChanged()` — avoids
  /// drifting `&+=` bumps in five places. Wraps via `&+=`; consumers compare
  /// interpolated strings, which handles the wrap.
  private(set) var refreshVersion = 0
  /// Rendered-entries payload bubbled up from `EntryListView` via the
  /// `VisibleEntriesKey` preference: the visible ids (Tab-into-list) plus
  /// the rendered-unread ids — the rendered side of the two-sided
  /// `pendingReadIDs` retention prune (issue #148).
  var visibleEntries: VisibleEntriesPayload = .empty

  /// Single point that invalidates the article list's data refresh
  /// (pre-split name: `bumpEntryList`).
  func noteDataChanged() {
    refreshVersion &+= 1
  }

  /// Adopt a freshly fetched sidebar snapshot (the `SidebarInner` refresh
  /// task's apply hook).
  func applySnapshot(_ snapshot: UnreadCountsSnapshot) {
    self.snapshot = snapshot
  }

  /// Insert one optimistic pending-read — the yield-deferred
  /// selection-commit path (`applyPendingReadAfterYield`).
  func insertPendingRead(feedbinEntryID: Int) {
    pendingReadIDs.insert(feedbinEntryID)
  }

  /// Prune the optimistic-read overlay with the TWO-SIDED retention
  /// criterion (issue #148, `retainedPendingReadIDs`): an ID is released
  /// only once BOTH the unread snapshot AND the currently-rendered rows
  /// confirm the committed `isRead == true`. Both sides are properties of
  /// THIS model, so the evaluation is atomic — no caller can pass a stale
  /// side. Called from the snapshot-change trigger and from the
  /// `VisibleEntriesKey` preference change.
  func prune() {
    guard !pendingReadIDs.isEmpty else { return }
    pendingReadIDs = retainedPendingReadIDs(
      pending: pendingReadIDs,
      snapshotUnread: snapshot.unreadFeedbinEntryIDs,
      renderedUnread: visibleEntries.unreadFeedbinEntryIDs
    )
  }

  /// Optimistically mark everything under `target` read and return the
  /// writer's mark target. The overlay grows in the same frame, so the
  /// sidebar can drop to zero as the article list empties — without waiting
  /// for the background writer to commit and the snapshot refresh to land.
  /// The pre-computed `unreadIDByFolder` / `unreadIDByCategory` dictionaries
  /// already group by the same axis the user selected.
  func markAllOptimistically(target: SidebarSelection) -> MarkReadTarget {
    let markTarget: MarkReadTarget
    let optimisticIDs: Set<Int>
    switch target {
    case .folder(let label):
      markTarget = .folder(label)
      optimisticIDs = snapshot.unreadIDByFolder[label] ?? []
    case .category(let label):
      markTarget = .category(label)
      optimisticIDs = snapshot.unreadIDByCategory[label] ?? []
    }
    pendingReadIDs.formUnion(optimisticIDs)
    return markTarget
  }
}
