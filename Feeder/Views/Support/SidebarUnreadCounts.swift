import Foundation

// Pure aggregation helper for sidebar unread badges.
//
// The sidebar runs a single `@Query` over classified-unread entries and the
// result is projected — once per body evaluation, lifted into `let`-locals so
// SwiftUI does not recompute on every property access — into per-category and
// per-folder count dictionaries. Aggregation is O(unread) and runs over the
// snapshot only; never per rendered row. Extracted as a `nonisolated` pure
// function so it can be unit-tested without spinning up a SwiftUI host.

/// Counts how many times each non-empty label appears in `labels` and returns
/// the result as a `[label: count]` dictionary.
///
/// Empty labels are skipped because they signal "no folder assigned" (root
/// category entries) or "no category yet" (unclassified entries that already
/// do not appear in the sidebar) — neither should contribute to any badge.
nonisolated func unreadCounts(in labels: some Sequence<String>) -> [String: Int] {
  var counts: [String: Int] = [:]
  for label in labels where !label.isEmpty {
    counts[label, default: 0] += 1
  }
  return counts
}
