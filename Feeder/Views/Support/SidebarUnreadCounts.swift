import Foundation

/// Pure aggregation helpers for sidebar unread badges.
///
/// The sidebar runs a single `@Query` over classified-unread entries and
/// projects the result into per-category and per-folder count dictionaries.
/// Aggregation is O(unread) and runs once per `@Query` snapshot — never per
/// rendered row. Extracted as `nonisolated` pure functions so they can be
/// unit-tested without spinning up a SwiftUI host.

/// Map of category label → unread count, derived from the entries' denormalized
/// `primaryCategory` field. Entries with an empty `primaryCategory` are
/// skipped — those are unclassified rows that already do not appear in the
/// sidebar.
nonisolated func unreadCountsByCategory(_ categoryLabels: some Sequence<String>) -> [String: Int] {
  var counts: [String: Int] = [:]
  for label in categoryLabels where !label.isEmpty {
    counts[label, default: 0] += 1
  }
  return counts
}

/// Map of folder label → unread count, derived from the entries' denormalized
/// `primaryFolder` field. Entries assigned to a root-level category (empty
/// `primaryFolder`) are not surfaced under any folder badge.
nonisolated func unreadCountsByFolder(_ folderLabels: some Sequence<String>) -> [String: Int] {
  var counts: [String: Int] = [:]
  for label in folderLabels where !label.isEmpty {
    counts[label, default: 0] += 1
  }
  return counts
}
