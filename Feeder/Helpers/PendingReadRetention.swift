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
