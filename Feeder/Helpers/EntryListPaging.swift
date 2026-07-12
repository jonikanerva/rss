import Foundation
import SwiftData

// MARK: - Article-list paging math (pure, issue #151)

/// True when a paged fetch filled its whole window — the store may hold more
/// rows. `fetchedCount == limit` with the store total exactly equal to the
/// limit is a benign false positive: the next grow refetches, comes back
/// short, and `hasMore` settles false — one no-op grow instead of a COUNT
/// query on every fetch.
nonisolated func hasMorePages(fetchedCount: Int, limit: Int) -> Bool {
  fetchedCount >= limit
}

/// The next window size after an append request. Growth is monotonic — the
/// window only ever grows within one structural context; the structural
/// reload resets it to the initial cap.
nonisolated func nextRowLimit(current: Int, growthStep: Int) -> Int {
  current + growthStep
}

/// Index of the row whose appearance requests the next append — `margin`
/// rows before the window end, so the grown refetch usually lands before the
/// user reaches the bottom. Clamped into the valid index range for windows
/// smaller than the margin; nil for an empty window.
nonisolated func appendTriggerIndex(fetchedCount: Int, margin: Int) -> Int? {
  guard fetchedCount > 0 else { return nil }
  return min(fetchedCount - 1, max(0, fetchedCount - margin))
}

/// True when `new` merely extends `previous` at the tail: every previously
/// rendered row kept its position, so the anchor-restore scroll is skipped —
/// nothing the user is looking at moved (issue #151's scroll-jump rule).
/// Computed reader-side so MainActor never pays an O(window) comparison on a
/// per-event refresh tick.
nonisolated func isPrefixExtension(
  previous: [PersistentIdentifier], new: [PersistentIdentifier]
) -> Bool {
  !previous.isEmpty && new.count > previous.count && new.starts(with: previous)
}

/// Window size that covers a pinned row at 1-based `pinPosition` in the
/// sorted result — never smaller than the requested window. Chronology stays
/// continuous: the pin is covered by GROWING the prefix, never by unioning
/// the pinned row out-of-band (which would render a timeline gap).
nonisolated func effectiveRowLimit(requested: Int, pinPosition: Int) -> Int {
  max(requested, pinPosition)
}
