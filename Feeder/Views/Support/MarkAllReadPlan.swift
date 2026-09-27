import Foundation

// MARK: - Mark-all-read plan (pure)

nonisolated struct MarkAllReadPlan: Sendable, Equatable {
  let markTarget: MarkReadTarget
  /// The target's unread IDs in the cached snapshot. The caller adds them to
  /// the optimistic overlay, so the badges drop in the same frame, before the
  /// writer commits.
  let optimisticIDs: Set<Int>
  /// `true` only when the target is the current sidebar selection. Otherwise
  /// the open article stays selected and pinned in the list.
  let clearsArticleSelection: Bool
}

nonisolated func markAllReadPlan(
  for target: SidebarSelection, currentSelection: SidebarSelection?,
  snapshot: UnreadCountsSnapshot
) -> MarkAllReadPlan {
  let clearsArticleSelection = target == currentSelection
  switch target {
  case .folder(let label):
    return MarkAllReadPlan(
      markTarget: .folder(label),
      optimisticIDs: snapshot.unreadIDByFolder[label] ?? [],
      clearsArticleSelection: clearsArticleSelection)
  case .category(let label):
    return MarkAllReadPlan(
      markTarget: .category(label),
      optimisticIDs: snapshot.unreadIDByCategory[label] ?? [],
      clearsArticleSelection: clearsArticleSelection)
  }
}
