import Foundation
import Testing

@testable import Feeder

// MARK: - Pending-read yield-then-insert contract
//
// Regression coverage for the article-list keyboard-nav perf bug. Before the
// fix `ContentView` mutated `pendingReadIDs` inline inside the selection
// `.onChange` handler (now `.onChange(of: selectedEntryID)`, issue #148),
// which cascaded through the sidebar unread aggregation and `EntryRowView`'s
// dimming overlay on the same frame the selection committed — visible as
// arrow-down feeling sluggish. The fix
// routes the mutation through `applyPendingReadAfterYield`, which schedules
// a `Task { @MainActor in await Task.yield(); apply(id) }`. Tests pin the
// contract: synchronous observation must show the overlay unchanged; after
// awaiting the returned Task, the insertion has happened.

@MainActor
struct PendingReadAfterYieldTests {
  /// Captures the same shape `ContentView` owns — a `Set<Int>` overlay the
  /// helper mutates through the supplied closure.
  private final class State {
    var pendingReadIDs: Set<Int> = []
  }

  @Test
  func mutationIsDeferredOffTheCallingFrame() async {
    // Pinning the "selection commit returns before the overlay grows" half
    // of the contract: the caller observes the overlay as it was at the
    // moment of the call, not the state after the deferred mutation lands.
    // On the pre-fix code (synchronous insert) this assertion would fail.
    let state = State()
    let task = applyPendingReadAfterYield(feedbinEntryID: 42) { id in
      state.pendingReadIDs.insert(id)
    }
    // Synchronously — before any yield point — the overlay is unchanged.
    #expect(state.pendingReadIDs.isEmpty)
    // Drain the spawned Task so the unstructured work doesn't leak into
    // the next test through shared MainActor scheduling state.
    await task.value
  }

  @Test
  func mutationLandsAfterTheSpawnedTaskCompletes() async {
    // After awaiting the returned Task, the closure has applied. A pre-fix
    // synchronous insert would also satisfy this expect (the overlay
    // would already be `[42]` before any wait), so this test pairs with
    // `mutationIsDeferredOffTheCallingFrame` above: together they exclude
    // both "never lands" and "lands immediately".
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
