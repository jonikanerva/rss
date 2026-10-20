import Foundation

/// The newest Feedbin `created_at` that a complete, successful entry fetch
/// covered. The value is on the Feedbin server clock, never on the Mac clock,
/// because Feedbin compares `since` with `created_at` on its own clock.
nonisolated struct EntryCoverageCursor: Equatable, Sendable {
  /// The next fetch asks for entries created after `newestCreatedAt` minus
  /// this window. The window covers an exclusive `since`, entries with equal
  /// `created_at`, the millisecond `since` format, and an entry that becomes
  /// visible on the server after a newer entry. Rows that the window fetches
  /// again are skipped by `feedbinEntryID`.
  static let overlap: TimeInterval = 10 * 60

  let newestCreatedAt: Date

  /// The `since` of the next fetch. Without a cursor the fetch covers the full
  /// retention window. The fetch never reaches further back than `cutoff`.
  static func since(after cursor: EntryCoverageCursor?, cutoff: Date) -> Date {
    guard let cursor else { return cutoff }
    return max(cursor.newestCreatedAt.addingTimeInterval(-overlap), cutoff)
  }

  /// The cursor after a successful fetch whose newest entry has
  /// `newestCreatedAt`. An empty fetch keeps the cursor, and the cursor never
  /// moves back.
  static func advanced(_ cursor: EntryCoverageCursor?, by newestCreatedAt: Date?) -> EntryCoverageCursor? {
    guard let newestCreatedAt else { return cursor }
    guard let cursor else { return EntryCoverageCursor(newestCreatedAt: newestCreatedAt) }
    return EntryCoverageCursor(newestCreatedAt: max(cursor.newestCreatedAt, newestCreatedAt))
  }
}
