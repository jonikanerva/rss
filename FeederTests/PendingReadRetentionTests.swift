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

  // MARK: - Off-window overlay IDs (issue #151 — render cap)
  //
  // The `VisibleEntriesPayload` stays FULL-RESULT under the render cap (the
  // binding invariant pair — see `EntryListView.visibleEntries` and
  // `EntryRowView.isRead`), so `renderedUnread` here covers every DTO the
  // slice can ever reveal — including rows the user read locally while they
  // sat beyond the rendered window. These cases pin the safety story for
  // revealing cached tail DTOs.

  @Test
  func offWindowOverlayIDIsRetainedUntilAFetchConfirms() {
    // Row 9 was read locally while beyond the rendered window. Both sides
    // still count it unread (no refetch has confirmed the flip), so the
    // overlay survives — a cached stale-unread DTO scrolling into view
    // renders DIMMED via the overlay term, never stale-unread.
    #expect(
      retainedPendingReadIDs(pending: [9], snapshotUnread: [9], renderedUnread: [9, 1]) == [9])
  }

  @Test
  func offWindowOverlayIDReleasesOnlyOnDoubleConfirmation() {
    // Only once BOTH refetched sources confirm the committed read does the
    // overlay release the ID — by then the full-result payload no longer
    // lists it as unread, so nothing revealable can render stale.
    #expect(retainedPendingReadIDs(pending: [9], snapshotUnread: [], renderedUnread: []).isEmpty)
    // One-sided confirmation retains — landing order stays irrelevant.
    #expect(retainedPendingReadIDs(pending: [9], snapshotUnread: [9], renderedUnread: []) == [9])
    #expect(retainedPendingReadIDs(pending: [9], snapshotUnread: [], renderedUnread: [9]) == [9])
  }
}
