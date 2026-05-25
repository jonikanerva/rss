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

/// One `(label, feedbinEntryID)` pair fed into the pending-aware aggregator.
/// The label is whatever the sidebar is grouping by (category or folder); the
/// id is what `pendingReadIDs` keys on so we can exclude entries the user has
/// already marked read optimistically.
nonisolated struct UnreadCountInput: Sendable, Equatable {
  let label: String
  let feedbinEntryID: Int
}

/// Counts how many times each non-empty label appears in `entries`, skipping
/// any entry whose `feedbinEntryID` is in `excludingFeedbinEntryIDs`.
///
/// The exclusion set is the MainActor's `pendingReadIDs` — entries the user
/// has just opened (J/K scrub) or bulk-marked (mark-all-read) but whose
/// `isRead` write has not yet landed in the SwiftData store. Subtracting
/// them keeps the sidebar badge in step with the dimmed article-list rows
/// in the same frame, without having to flip `isRead` eagerly and defeat
/// the existing debounce design.
nonisolated func unreadCounts(
  in entries: some Sequence<UnreadCountInput>,
  excludingFeedbinEntryIDs excluded: Set<Int>
) -> [String: Int] {
  var counts: [String: Int] = [:]
  for entry in entries where !entry.label.isEmpty && !excluded.contains(entry.feedbinEntryID) {
    counts[entry.label, default: 0] += 1
  }
  return counts
}

/// Builds the per-category and per-folder unread-count dictionaries in a
/// single pass over the `unreadEntries` snapshot.
///
/// The production sidebar needs both aggregations and they share the same
/// exclusion check against `pendingReadIDs`. Running two `Entry → DTO → loop`
/// passes (one per axis) doubled the iteration and allocated an intermediate
/// `[UnreadCountInput]` array each time. This overload reads the model fields
/// once per entry and emits both dictionaries together. The two-arg
/// `UnreadCountInput` overload above is retained for unit-tested aggregation
/// behaviour — neither shape needs to change for those tests to keep
/// asserting the contract.
@MainActor
func unreadCounts(
  in entries: [Entry],
  excludingFeedbinEntryIDs excluded: Set<Int>
) -> (category: [String: Int], folder: [String: Int]) {
  var category: [String: Int] = [:]
  var folder: [String: Int] = [:]
  for entry in entries where !excluded.contains(entry.feedbinEntryID) {
    if !entry.primaryCategory.isEmpty {
      category[entry.primaryCategory, default: 0] += 1
    }
    if !entry.primaryFolder.isEmpty {
      folder[entry.primaryFolder, default: 0] += 1
    }
  }
  return (category, folder)
}
