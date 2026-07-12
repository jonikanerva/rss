import Testing

@testable import Feeder

// MARK: - retainedPendingReadIDs (two-sided overlay retention, issue #148)

/// Pure, container-free pins for the two-sided prune criterion: an overlay ID
/// is released only once BOTH the unread snapshot AND the rendered rows
/// confirm the committed `isRead == true`.
struct PendingReadRetentionTests {
  @Test
  func idStillUnreadInSnapshotOnlyIsRetained() {
    #expect(retainedPendingReadIDs(pending: [1], snapshotUnread: [1], renderedUnread: []) == [1])
  }

  @Test
  func idStillUnreadInRenderedRowsOnlyIsRetained() {
    // The flicker case the two-sided criterion exists for: the snapshot
    // refresh landed first and already dropped the id, but the rendered row
    // DTOs have not refetched yet — the overlay must survive so no frame
    // renders the row stale-unread without its dim.
    #expect(retainedPendingReadIDs(pending: [1], snapshotUnread: [], renderedUnread: [1]) == [1])
  }

  @Test
  func idConfirmedReadByBothSidesIsReleased() {
    #expect(retainedPendingReadIDs(pending: [1], snapshotUnread: [], renderedUnread: []).isEmpty)
  }

  @Test
  func mixedOverlayPartitionsPerID() {
    #expect(
      retainedPendingReadIDs(pending: [1, 2, 3, 4], snapshotUnread: [1], renderedUnread: [2])
        == [1, 2])
  }

  @Test
  func unreadIDsOutsideTheOverlayNeverEnterIt() {
    #expect(retainedPendingReadIDs(pending: [], snapshotUnread: [5], renderedUnread: [6]).isEmpty)
  }

  @Test
  func emptySourcesReleaseEverything() {
    #expect(
      retainedPendingReadIDs(pending: [1, 2], snapshotUnread: [], renderedUnread: []).isEmpty)
  }
}
