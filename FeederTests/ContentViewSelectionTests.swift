import Foundation
import Testing

@testable import Feeder

// MARK: - Pending-read yield-then-insert contract
//
// Mutating the overlay inside the selection handler cascades through the
// sidebar aggregation and the row dimming overlay on the same frame the
// selection commits, which the user feels as sluggish arrow-key navigation.
// Routing it through `applyPendingReadAfterYield` defers it one tick.
//
// These tests pin that contract: a synchronous observation must show the
// overlay unchanged, and awaiting the returned task must show the insertion.

@MainActor
struct PendingReadAfterYieldTests {
  /// Captures the same shape `ContentView` owns — a `Set<Int>` overlay the
  /// helper mutates through the supplied closure.
  private final class State {
    var pendingReadIDs: Set<Int> = []
  }

  @Test
  func mutationIsDeferredOffTheCallingFrame() async {
    // The caller observes the overlay as it was at the moment of the call, not
    // the state after the deferred mutation lands. A synchronous insert would
    // fail this assertion.
    let state = State()
    let task = applyPendingReadAfterYield(feedbinEntryID: 42) { id in
      state.pendingReadIDs.insert(id)
    }
    // Synchronously — before any yield point — the overlay is unchanged.
    #expect(state.pendingReadIDs.isEmpty)
    // Drain the spawned task, so its work does not leak into the next test
    // through shared MainActor scheduling state.
    await task.value
  }

  @Test
  func mutationLandsAfterTheSpawnedTaskCompletes() async {
    // Awaiting the returned task shows the closure applied. A synchronous
    // insert would satisfy this alone, so it pairs with the deferral test above:
    // together they exclude both "never lands" and "lands immediately".
    let state = State()
    let task = applyPendingReadAfterYield(feedbinEntryID: 42) { id in
      state.pendingReadIDs.insert(id)
    }
    await task.value
    #expect(state.pendingReadIDs == [42])
  }

  @Test
  func multipleScheduledMutationsAccumulate() async {
    // Holding the down-arrow key drives N selection-commit events in
    // quick succession; the deferred mutations must all eventually land
    // (the overlay is the union of every scrubbed-past unread). No call is
    // dropped on the floor by the yield indirection.
    let state = State()
    let tasks = [1, 2, 3].map { id in
      applyPendingReadAfterYield(feedbinEntryID: id) { incoming in
        state.pendingReadIDs.insert(incoming)
      }
    }
    #expect(state.pendingReadIDs.isEmpty)
    for task in tasks {
      await task.value
    }
    #expect(state.pendingReadIDs == [1, 2, 3])
  }
}
