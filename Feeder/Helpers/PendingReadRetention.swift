import Foundation

// MARK: - Pending-read overlay retention (pure criterion)

/// Two-sided retention criterion for the optimistic `pendingReadIDs` overlay:
/// an ID survives while either the sidebar unread snapshot or the rendered rows
/// still show it unread. Dropping it needs both refetched sources to confirm
/// the committed state, so no frame renders a stale-unread row whichever fetch
/// lands first.
nonisolated func retainedPendingReadIDs(
  pending: Set<Int>, snapshotUnread: Set<Int>, renderedUnread: Set<Int>
) -> Set<Int> {
  pending.intersection(snapshotUnread.union(renderedUnread))
}

/// Retention criterion for the optimistic `pendingUnreadIDs` overlay: an ID
/// survives until both the sidebar unread snapshot and the rendered rows show
/// it unread, so no frame renders a stale-read row whichever fetch lands first.
nonisolated func retainedPendingUnreadIDs(
  pending: Set<Int>, snapshotUnread: Set<Int>, renderedUnread: Set<Int>
) -> Set<Int> {
  pending.subtracting(snapshotUnread.intersection(renderedUnread))
}

/// The read state that the window shows for one article. A pending read wins
/// over a pending unread, and both win over the stored state.
nonisolated func effectiveIsRead(
  feedbinEntryID id: Int, storeIsRead: Bool, pendingRead: Set<Int>, pendingUnread: Set<Int>
) -> Bool {
  if pendingRead.contains(id) { return true }
  if pendingUnread.contains(id) { return false }
  return storeIsRead
}
