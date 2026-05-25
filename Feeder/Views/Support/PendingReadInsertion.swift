import Foundation

// MARK: - Yield-then-insert helper for the pending-read overlay
//
// `ContentView` mutates `pendingReadIDs` whenever the user navigates to a new
// unread article. Doing that synchronously inside the `.onChange(of:
// selectedEntry)` closure runs the mutation on the same frame the selection
// commit fires — and `pendingReadIDs` is observed by both the sidebar's
// unread-count aggregation and `EntryRowView`'s dimming overlay, so the
// mutation cascades through two render passes before the next keystroke can
// be processed. Arrow-down on the article list feels sluggish as a result.
//
// `applyPendingReadAfterYield` defers the mutation by one cooperative tick:
// the selection write lands first, then the overlay updates next frame. This
// preserves the eventual mark-as-read semantics — the optimistic overlay is
// still owned by `pendingReadIDs`, and `flushPendingReads` / `markAllAsRead`
// drain on the same paths.
//
// The helper is extracted so it can be unit-tested without spinning up a
// SwiftUI host: the contract is "after the call site returns, no mutation
// has happened yet; after the first `await Task.yield()` it has". The test
// suite asserts both halves.

/// Returns the spawned `Task` so callers that need to await completion (the
/// unit-test suite) can do so deterministically without
/// `withCheckedContinuation` or wallclock sleeps. `ContentView` discards the
/// return value — the production call site is fire-and-forget.
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
