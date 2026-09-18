import Foundation

// Pure aggregation helpers for the sidebar unread badges.
//
// Aggregation over the live unread universe runs on the reader actor. The
// sidebar then overlays the optimistic `pendingReadIDs` set on that snapshot
// through the helpers below.
//
// The `unreadCounts(in:)` overloads pin the same contract the snapshot
// implements off-actor, so the cached path can be cross-checked against a pure
// helper with no container and no SwiftUI host.

/// Count how many times each non-empty label appears in `labels`. An empty
/// label means "no folder assigned" or "no category yet", and neither may
/// contribute to a badge.
nonisolated func unreadCounts(in labels: some Sequence<String>) -> [String: Int] {
  var counts: [String: Int] = [:]
  for label in labels where !label.isEmpty {
    counts[label, default: 0] += 1
  }
  return counts
}

/// One label-and-id pair for the pending-aware aggregator. The label is
/// whatever the sidebar groups by; the id is what `pendingReadIDs` keys on.
nonisolated struct UnreadCountInput: Sendable, Equatable {
  let label: String
  let feedbinEntryID: Int
}

/// Count each non-empty label in `entries`, skipping any entry in
/// `excludingFeedbinEntryIDs`. That exclusion set is the optimistic overlay:
/// entries the user has marked read whose write has not yet landed. Subtracting
/// them keeps the badge in step with the dimmed rows in the same frame.
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

/// Per category, how many of the snapshot's unread entries the user has marked
/// read optimistically. The sidebar subtracts these, so a badge tracks the
/// dimmed rows in the same frame.
///
/// The intersection runs over the snapshot's stored id set, so a pending ID
/// that is no longer unread on disk matches nothing and a cross-device flip
/// cannot double-subtract.
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

/// Folder-axis sibling of `pendingReadCountsByCategory`, with the same
/// contract.
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
  /// Subtract `other` from self, floored at zero, into a new dictionary. Used
  /// to overlay the pending-read counts on a cached snapshot without mutating
  /// either input.
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
