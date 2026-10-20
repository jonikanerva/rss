import Foundation
import Testing

@testable import Feeder

// MARK: - DataWriter Purge Tests

/// Exercises `DataWriter.purgeEntriesOlderThan(_:now:)`. The purge is a
/// runtime delete keyed on `publishedAt` and the `now` instant. Every test
/// passes the same fixed whole-second `now`, so an entry can sit exactly at
/// the cutoff. Purge is NOT a schema migration (`STACK.md § 5`).
struct DataWriterPurgeTests {
  /// Whole seconds, so the millisecond wire format round-trips it exactly.
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)

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

    let old = try makeEntry(id: 1001, daysAgo: 31, from: Self.now)
    let recent = try makeEntry(id: 1002, daysAgo: 29, from: Self.now)
    let today = try makeEntry(id: 1003, daysAgo: 0, from: Self.now)

    _ = try await writer.persistEntries(
      [old, recent, today], unreadIDs: Set([1001, 1002, 1003]))

    let outcome = try await writer.purgeEntriesOlderThan(30, now: Self.now)

    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast, limit: .max)
    let remainingIDs = Set(remaining.map(\.entryID))
    #expect(remainingIDs == [1002, 1003])
  }

  // MARK: - Boundary

  /// The predicate is strict `<` on raw seconds: an entry 1 s before the
  /// cutoff goes, and entries at the cutoff and 1 s after it stay.
  @Test
  func purgeBoundaryIsStrictLessThan() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let cutoff = Self.now.addingTimeInterval(-30 * 86_400)
    let entries = try [(2001, -1.0), (2002, 0.0), (2003, 1.0)].map { id, offset in
      try FeedbinFixtures.entry(
        id: id,
        title: "Entry \(id)",
        published: formatDateForFeedbin(cutoff.addingTimeInterval(offset))
      )
    }

    _ = try await writer.persistEntries(entries, unreadIDs: Set([2001, 2002, 2003]))

    let outcome = try await writer.purgeEntriesOlderThan(30, now: Self.now)

    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast, limit: .max)
    let remainingIDs = Set(remaining.map(\.entryID))
    #expect(remainingIDs == [2002, 2003])
  }

  // MARK: - No-op

  /// Calling purge on an empty store must succeed and report zero deletions
  /// — the writer's early-return path stays exercised so a future refactor
  /// that drops it surfaces in tests.
  @Test
  func purgeOnEmptyStoreIsNoOp() async throws {
    let writer = try await makeWriter()

    let outcome = try await writer.purgeEntriesOlderThan(30, now: Self.now)
    #expect(outcome.purgedCount == 0)
  }

  /// Purge when every row is newer than the cutoff returns zero and leaves
  /// all entries in place.
  @Test
  func purgeWithAllRecentEntriesKeepsAllRows() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let recent1 = try makeEntry(id: 3001, daysAgo: 1, from: Self.now)
    let recent2 = try makeEntry(id: 3002, daysAgo: 15, from: Self.now)
    let recent3 = try makeEntry(id: 3003, daysAgo: 29, from: Self.now)
    _ = try await writer.persistEntries(
      [recent1, recent2, recent3], unreadIDs: Set([3001, 3002, 3003]))

    let outcome = try await writer.purgeEntriesOlderThan(30, now: Self.now)
    #expect(outcome.purgedCount == 0)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast, limit: .max)
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

    let twoDaysOld = try makeEntry(id: 4001, daysAgo: 2, from: Self.now)
    let today = try makeEntry(id: 4002, daysAgo: 0, from: Self.now)
    _ = try await writer.persistEntries(
      [twoDaysOld, today], unreadIDs: Set([4001, 4002]))

    let outcome = try await writer.purgeEntriesOlderThan(1, now: Self.now)
    #expect(outcome.purgedCount == 1)

    let remaining = try await writer.fetchUnclassifiedInputs(cutoffDate: .distantPast, limit: .max)
    #expect(remaining.map(\.entryID) == [4002])
  }
}
