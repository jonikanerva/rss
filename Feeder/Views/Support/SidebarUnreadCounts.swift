import Foundation

// Pure aggregation helpers for sidebar unread badges.
//
// Aggregation over the live unread universe runs off-MainActor on the
// `DataReader` actor, producing an `UnreadCountsSnapshot` (see
// `DataReader.fetchUnreadCountsSnapshot()`). The sidebar then overlays
// the optimistic `pendingReadIDs` set on top of that snapshot via the
// `pendingReadCountsBy*` + `subtractingPendingCounts` helpers below.
//
// The two top-level `unreadCounts(in:)` overloads are retained as pure
// aggregation helpers used by unit tests — they pin the same contract the
// snapshot now implements off-actor, so a future regression in the cached
// path can be cross-checked against the pure helper without spinning up a
// SwiftUI host or a SwiftData container.

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

// MARK: - Pending-overlay subtraction over a cached snapshot

/// Counts, per category, how many of an `UnreadCountsSnapshot`'s unread
/// entries the user has just optimistically marked read but whose write has
/// not yet landed in SwiftData. The sidebar subtracts these from
/// `snapshot.categoryCounts` so the badge tracks the dimmed article-list
/// rows in the same frame the user pressed J/K or Mark-All-Read — without
/// having to materialize `@Query unreadEntries` on MainActor.
///
/// Iteration is bounded by the number of unique categories times the size of
/// the small `pending` set (typically 1–N). The intersection runs over the
/// stored `Set<Int>` so a pending ID that is no longer unread on disk simply
/// matches nothing and contributes zero — cross-device read flips do not
/// double-subtract.
nonisolated func pendingReadCountsByCategory(
  snapshot: UnreadCountsSnapshot, pending: Set<Int>
) -> [String: Int] {
  guard !pending.isEmpty else { return [:] }
  var result: [String: Int] = [:]
  for (category, ids) in snapshot.unreadIDByCategory {
    let count = pending.intersection(ids).count
    if count > 0 { result[category] = count }
  }
  return result
}

/// Folder-axis sibling of `pendingReadCountsByCategory`. Same shape, same
/// contract; kept as a separate function so the sidebar's badge derivation
/// reads as two parallel one-liners instead of branching on an axis enum.
nonisolated func pendingReadCountsByFolder(
  snapshot: UnreadCountsSnapshot, pending: Set<Int>
) -> [String: Int] {
  guard !pending.isEmpty else { return [:] }
  var result: [String: Int] = [:]
  for (folder, ids) in snapshot.unreadIDByFolder {
    let count = pending.intersection(ids).count
    if count > 0 { result[folder] = count }
  }
  return result
}

extension [String: Int] {
  /// Subtract `other` from self, floored at zero. Returns a new dictionary
  /// with the difference for every key in self. Used to overlay
  /// pending-read counts onto a cached snapshot's `categoryCounts` /
  /// `folderCounts` without mutating either input.
  ///
  /// Bounded by the number of keys in self (= unique categories or unique
  /// folders), which is tiny — the whole operation costs less than a single
  /// dictionary lookup did under the old MainActor aggregation.
  nonisolated func subtractingPendingCounts(_ other: [String: Int]) -> [String: Int] {
    guard !other.isEmpty else { return self }
    var result = self
    for (key, pending) in other {
      guard let current = result[key] else { continue }
      let next = current - pending
      if next > 0 {
        result[key] = next
      } else {
        result.removeValue(forKey: key)
      }
    }
    return result
  }
}
