import Foundation

// MARK: - Mark-all-read plan (pure)

nonisolated struct MarkAllReadPlan: Sendable, Equatable {
  let markTarget: EntryScope
  /// Narrows `markTarget` to the matching entries. Only the current list
  /// carries a search; another sidebar row marks its whole scope.
  let search: ArticleSearchTerm?
  /// The target's unread IDs in the cached snapshot. The caller adds them to
  /// the optimistic overlay, so the badges drop in the same frame, before the
  /// writer commits.
  let optimisticIDs: Set<Int>
  /// `true` only when the target is the current sidebar selection. Otherwise
  /// the open article stays selected and pinned in the list.
  let clearsArticleSelection: Bool

  init(
    markTarget: EntryScope, search: ArticleSearchTerm? = nil, optimisticIDs: Set<Int>,
    clearsArticleSelection: Bool
  ) {
    self.markTarget = markTarget
    self.search = search
    self.optimisticIDs = optimisticIDs
    self.clearsArticleSelection = clearsArticleSelection
  }
}

/// `search` and `renderedUnreadIDs` describe the current list. With a search,
/// the snapshot cannot tell which unread rows match, so the optimistic IDs are
/// the unread rows that the list shows; the write still covers every match.
nonisolated func markAllReadPlan(
  for target: SidebarSelection, currentSelection: SidebarSelection?,
  snapshot: UnreadCountsSnapshot, search: ArticleSearchTerm? = nil,
  renderedUnreadIDs: Set<Int> = []
) -> MarkAllReadPlan {
  let isCurrentList = target == currentSelection
  let markTarget: EntryScope
  let scopeIDs: Set<Int>
  switch target {
  case .allArticles:
    markTarget = .all
    scopeIDs = snapshot.unreadFeedbinEntryIDs
  case .folder(let label):
    markTarget = .folder(label)
    scopeIDs = snapshot.unreadIDByFolder[label] ?? []
  case .category(let label):
    markTarget = .category(label)
    scopeIDs = snapshot.unreadIDByCategory[label] ?? []
  }
  guard isCurrentList, let search else {
    return MarkAllReadPlan(
      markTarget: markTarget, optimisticIDs: scopeIDs, clearsArticleSelection: isCurrentList)
  }
  return MarkAllReadPlan(
    markTarget: markTarget, search: search,
    optimisticIDs: scopeIDs.intersection(renderedUnreadIDs), clearsArticleSelection: true)
}
