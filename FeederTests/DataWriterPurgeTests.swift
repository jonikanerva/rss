import Foundation
import Testing

@testable import Feeder

// MARK: - DataWriter Purge Tests

/// Exercises `DataWriter.purgeEntriesOlderThan(_:)`. The purge is a pure
/// runtime delete keyed on `publishedAt` and `Date.now`; tests seed entries
/// at deterministic offsets relative to the call site's "now" so the
/// boundary semantics (`<` strict) stay verifiable without freezing the
/// clock. See `STACK.md` § Persistence shape — purge is NOT a schema
/// migration and lives alongside the other `DataWriter` write paths.
struct DataWriterPurgeTests {
  // MARK: - Helpers

  private func makeWriter() async throws -> DataWriter {
    try await DataWriterTestSupport.makeWriter()
  }

  private func seedFeed(_ writer: DataWriter) async throws {
    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
  }

  /// Build an entry whose `publishedAt` is `daysAgo` days before `referenceDate`.
  /// Uses the same ISO 8601 + fractional seconds format the production decoder
  /// expects so the fixture round-trips cleanly.
  private func makeEntry(
    id: Int,
    daysAgo: Double,
    from referenceDate: Date
  ) throws -> FeedbinEntry {
    let date = referenceDate.addingTimeInterval(-daysAgo * 86_400)
    return try FeedbinFixtures.entry(
      id: id,
      title: "Entry \(id)",
      published: formatDateForFeedbin(date)
    )
  }

  // MARK: - Happy path

  /// Seeds entries at 31, 29, and 0 days ago. After a 30-day purge only the
  /// 31-day-old row goes — the 29-day-old and today rows survive. Verifies
  /// the predicate uses strict `<` (entries exactly at the cutoff or newer
  /// are kept).
  @Test
  func purgeRemovesOnlyEntriesOlderThan30Days() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let now = Date()
    let old = try makeEntry(id: 1001, daysAgo: 31, from: now)
    let recent = try makeEntry(id: 1002, daysAgo: 29, from: now)
    let today = try makeEntry(id: 1003, daysAgo: 0, from: now)

    _ = try await writer.persistEntries(
      [old, recent, today], unreadIDs: Set([1001, 1002, 1003]))

    let outcome = try await writer.purgeEntriesOlderThan(30)

    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast)
    let remainingIDs = Set(remaining.map(\.entryID))
    #expect(remainingIDs == [1002, 1003])
  }

  // MARK: - Boundary

  /// An entry published *exactly* at the cutoff (`Date.now - days * 86_400`)
  /// must be retained — the predicate uses strict `<`. Seeding with a tiny
  /// sub-second offset on either side keeps the assertion deterministic
  /// despite the elapsed time between fixture build and purge call.
  @Test
  func purgeBoundaryIsStrictLessThan() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let now = Date()
    // 30 days + 1 second old → must be purged (strictly older than cutoff).
    let justOver = try FeedbinFixtures.entry(
      id: 2001,
      title: "Just over the boundary",
      published: formatDateForFeedbin(now.addingTimeInterval(-30 * 86_400 - 1))
    )
    // 30 days - 5 seconds old → must remain (newer than cutoff). The 5s
    // headroom absorbs the wall-clock drift between fixture construction
    // and the purge's own `Date()` read.
    let justUnder = try FeedbinFixtures.entry(
      id: 2002,
      title: "Just under the boundary",
      published: formatDateForFeedbin(now.addingTimeInterval(-30 * 86_400 + 5))
    )

    _ = try await writer.persistEntries(
      [justOver, justUnder], unreadIDs: Set([2001, 2002]))

    let outcome = try await writer.purgeEntriesOlderThan(30)

    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast)
    let remainingIDs = Set(remaining.map(\.entryID))
    #expect(remainingIDs == [2002])
  }

  // MARK: - No-op

  /// Calling purge on an empty store must succeed and report zero deletions
  /// — the writer's early-return path stays exercised so a future refactor
  /// that drops it surfaces in tests.
  @Test
  func purgeOnEmptyStoreIsNoOp() async throws {
    let writer = try await makeWriter()

    let outcome = try await writer.purgeEntriesOlderThan(30)
    #expect(outcome.purgedCount == 0)
  }

  /// Purge when every row is newer than the cutoff returns zero and leaves
  /// all entries in place.
  @Test
  func purgeWithAllRecentEntriesKeepsAllRows() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let now = Date()
    let recent1 = try makeEntry(id: 3001, daysAgo: 1, from: now)
    let recent2 = try makeEntry(id: 3002, daysAgo: 15, from: now)
    let recent3 = try makeEntry(id: 3003, daysAgo: 29, from: now)
    _ = try await writer.persistEntries(
      [recent1, recent2, recent3], unreadIDs: Set([3001, 3002, 3003]))

    let outcome = try await writer.purgeEntriesOlderThan(30)
    #expect(outcome.purgedCount == 0)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast)
    #expect(remaining.count == 3)
  }

  // MARK: - Day count semantics

  /// Verifies the writer owns the day-count math: passing `days = 1` deletes
  /// the 2-day-old row while leaving today's row, even though both are
  /// recent by the previous test's standard. Guards against a regression
  /// where the cutoff math drifts from the documented "now - days * 86_400"
  /// shape.
  @Test
  func purgeWithSmallerDayCountTrimsCloserToNow() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let now = Date()
    let twoDaysOld = try makeEntry(id: 4001, daysAgo: 2, from: now)
    let today = try makeEntry(id: 4002, daysAgo: 0, from: now)
    _ = try await writer.persistEntries(
      [twoDaysOld, today], unreadIDs: Set([4001, 4002]))

    let outcome = try await writer.purgeEntriesOlderThan(1)
    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast)
    #expect(remaining.map(\.entryID) == [4002])
  }
}
