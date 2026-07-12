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

  // MARK: - Off-window overlay IDs (issue #151 — row cap)
  //
  // Under the row cap, `renderedUnread` covers only the FETCHED window; an
  // overlay ID beyond it loses the rendered-side protection but keeps the
  // snapshot side (the sidebar snapshot is unpaged). An off-window row is
  // not rendered, so it cannot flicker; when the window later grows over it,
  // the grown-prefix refetch (the binding contract) delivers its committed
  // state in the same result that re-adds it to `renderedUnread`.

  @Test
  func offWindowOverlayIDIsRetainedOnTheSnapshotSide() {
    // Row 9 sits beyond the fetched window (not in renderedUnread) but the
    // unpaged snapshot still counts it unread — the overlay must survive so
    // a later window growth renders it dimmed, not stale-unread.
    #expect(retainedPendingReadIDs(pending: [9], snapshotUnread: [9], renderedUnread: [1]) == [9])
  }

  @Test
  func offWindowOverlayIDReleasesOnceTheSnapshotConfirms() {
    // Once the unpaged snapshot confirms the committed read, nothing rendered
    // references the ID — releasing it cannot un-dim a visible row.
    #expect(retainedPendingReadIDs(pending: [9], snapshotUnread: [], renderedUnread: [1]).isEmpty)
  }
}
