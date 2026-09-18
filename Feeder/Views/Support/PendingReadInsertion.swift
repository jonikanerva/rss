import Foundation

// MARK: - Yield-then-insert helper for the pending-read overlay
//
// Both the sidebar's unread aggregation and the row dimming overlay observe
// `pendingReadIDs`, so mutating it inside the selection-commit closure cascades
// through two render passes before the next keystroke is processed.
//
// `applyPendingReadAfterYield` defers the mutation by one cooperative tick: the
// selection write lands first and the overlay updates next frame. Its contract
// is that no mutation has happened when the call site returns, and it has after
// the first yield.

/// Returns the spawned `Task`, so a caller that must await completion can do so
/// without a continuation or a wall-clock sleep. The production call site
/// discards it.
@MainActor
@discardableResult
func applyPendingReadAfterYield(
  feedbinEntryID: Int,
  apply: @escaping @MainActor (Int) -> Void
) -> Task<Void, Never> {
  Task { @MainActor in
    await Task.yield()
    apply(feedbinEntryID)
  }
}
