import Foundation

// MARK: - Pending-read overlay retention (pure criterion)

/// Two-sided retention criterion for the optimistic `pendingReadIDs` overlay
/// (issue #148): an ID survives while EITHER the sidebar unread snapshot still
/// counts it unread OR the currently-rendered rows still show it unread. An
/// overlay ID is dropped only once BOTH refetched sources confirm the
/// committed `isRead == true`, so no frame can render a stale-unread row
/// regardless of which fetch (snapshot / sections) lands first. The one-sided
/// predecessor pruned on the snapshot alone, which could drop the overlay a
/// frame before the row DTOs refetched — a visible unread-weight flicker.
nonisolated func retainedPendingReadIDs(
  pending: Set<Int>, snapshotUnread: Set<Int>, renderedUnread: Set<Int>
) -> Set<Int> {
  pending.intersection(snapshotUnread.union(renderedUnread))
}
