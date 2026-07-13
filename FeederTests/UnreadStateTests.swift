import Foundation
import Testing

@testable import Feeder

// MARK: - UnreadState (issue #146 final fix)

/// Container-free pins for the unread-state owner: refresh-version
/// accountability, the atomic two-sided prune delegation, and the
/// mark-all-optimistic union.
@MainActor
struct UnreadStateTests {
  private static func snapshot(
    unread: Set<Int>, byCategory: [String: Set<Int>] = [:], byFolder: [String: Set<Int>] = [:]
  ) -> UnreadCountsSnapshot {
    UnreadCountsSnapshot(
      categoryCounts: byCategory.mapValues(\.count),
      folderCounts: byFolder.mapValues(\.count),
      unreadFeedbinEntryIDs: unread,
      unreadIDByCategory: byCategory,
      unreadIDByFolder: byFolder,
      totalUnread: unread.count
    )
  }

  @Test
  func noteDataChangedTicksMonotonically() {
    let state = UnreadState()
    #expect(state.refreshVersion == 0)
    state.noteDataChanged()
    state.noteDataChanged()
    #expect(state.refreshVersion == 2)
  }

  @Test
  func applySnapshotReplacesTheCachedAggregate() {
    let state = UnreadState()
    state.applySnapshot(Self.snapshot(unread: [1, 2]))
    #expect(state.snapshot.totalUnread == 2)
  }

  @Test
  func pruneDelegatesToTheTwoSidedCriterion() {
    // ID 1: unread on both sides → retained. ID 2: confirmed read by both
    // refetched sources → released. ID 3: still unread in the rendered rows
    // only → retained (the flicker case the two-sided criterion exists for).
    let state = UnreadState()
    state.insertPendingRead(feedbinEntryID: 1)
    state.insertPendingRead(feedbinEntryID: 2)
    state.insertPendingRead(feedbinEntryID: 3)
    state.applySnapshot(Self.snapshot(unread: [1]))
    state.visibleEntries = VisibleEntriesPayload(ids: [], unreadFeedbinEntryIDs: [1, 3])
    state.prune()
    #expect(state.pendingReadIDs == [1, 3])
  }

  @Test
  func markAllOptimisticallyUnionsTheAxisAndReturnsTheTarget() {
    let state = UnreadState()
    state.applySnapshot(
      Self.snapshot(
        unread: [1, 2, 3],
        byCategory: ["apple": [1, 2]],
        byFolder: ["tech": [1, 2, 3]]
      ))
    let categoryTarget = state.markAllOptimistically(target: .category("apple"))
    #expect(categoryTarget == .category("apple"))
    #expect(state.pendingReadIDs == [1, 2])
    let folderTarget = state.markAllOptimistically(target: .folder("tech"))
    #expect(folderTarget == .folder("tech"))
    #expect(state.pendingReadIDs == [1, 2, 3])
  }

  @Test
  func markAllOnAnEmptyAxisIsANoOpUnion() {
    let state = UnreadState()
    state.applySnapshot(Self.snapshot(unread: [9]))
    _ = state.markAllOptimistically(target: .category("empty"))
    #expect(state.pendingReadIDs.isEmpty)
  }
}
