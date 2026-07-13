import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Keyset paging integration pins (issue #155): pages tile exactly through an
/// equal-timestamp run, inserts above the cursor never shift a page seam, the
/// cursor row leaving the filter never skips rows, `hasMore` is exact at the
/// page boundary, and pin coverage grows the first page to the pinned row's
/// sort position. Runs against the production writer + reader pair on one
/// shared in-memory container; concurrent-coordinator pressure is capped by
/// the serial unit-target run (`make test` passes
/// `-parallel-testing-enabled NO`, STACK.md §14) — `.serialized` here only
/// orders tests within the suite.
@Suite("DataReader keyset paging", .serialized)
struct DataReaderPagingTests {
  /// Base instant for generated `published` timestamps — matches the
  /// fixture-default era so the ISO strings decode through the production
  /// Feedbin decoder.
  private static let base = Date(timeIntervalSince1970: 1_750_000_000)

  private static func publishedString(secondsBeforeBase seconds: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: base.addingTimeInterval(-Double(seconds)))
  }

  /// One seeded row: `id`, seconds before the base instant (bigger = older),
  /// and read state. Category is always `tech`.
  private struct RowSpec {
    let id: Int
    let age: Int
    let read: Bool

    init(id: Int, age: Int, read: Bool = false) {
      self.id = id
      self.age = age
      self.read = read
    }
  }

  /// Seed a feed, the `tech` category, and the given rows through the
  /// production write path (`persistEntries` + `applyClassification`), then
  /// return the writer + reader pair.
  private func makeSeededPair(_ specs: [RowSpec]) async throws -> (DataWriter, DataReader) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    try await writer.addCategory(
      label: "tech", displayName: "Tech", description: "Tech news", sortOrder: 0)
    let entries = try specs.map { spec in
      try FeedbinFixtures.entry(
        id: spec.id, title: "Story \(spec.id)",
        published: Self.publishedString(secondsBeforeBase: spec.age))
    }
    let unreadIDs = Set(specs.filter { !$0.read }.map(\.id))
    _ = try await writer.persistEntries(entries, unreadIDs: unreadIDs)
    for spec in specs {
      try await writer.applyClassification(
        entryID: spec.id,
        result: ClassificationResult(entryID: spec.id, categoryLabel: "tech", confidence: 0.9))
    }
    return (writer, reader)
  }

  private func fetch(
    _ reader: DataReader, window: EntryListWindow, pinned: Int? = nil, showRead: Bool = false
  ) async throws -> EntryListFetchResult {
    try await reader.fetchEntrySections(
      category: "tech", folder: nil, showRead: showRead,
      cutoffDate: .distantPast, pinnedFeedbinEntryID: pinned, window: window)
  }

  private func cursor(_ result: EntryListFetchResult) throws -> EntryListCursor {
    try #require(entryListCursor(of: result.sections))
  }

  private func rowIDs(_ result: EntryListFetchResult) -> [Int] {
    result.sections.flatMap(\.rows).map(\.feedbinEntryID)
  }

  // MARK: - Tiling

  /// Pages must tile the canonical order exactly — including through a run of
  /// EQUAL `publishedAt` values straddling a page boundary, where only the
  /// `feedbinEntryID` tiebreak orders the seam.
  @Test
  func keysetPagesTileExactly() async throws {
    // 25 rows; ids 1008–1012 share ONE timestamp and straddle the first page
    // boundary at K=10 (they sort 1012, 1011, 1010, 1009, 1008 by the id
    // tiebreak, positions 8–12).
    let specs = (1...25).map { index in
      RowSpec(id: 1000 + index, age: (8...12).contains(index) ? 600 : index * 60)
    }
    let (_, reader) = try await makeSeededPair(specs)

    let unbounded = try await fetch(reader, window: .firstPage(limit: 1000))
    let page1 = try await fetch(reader, window: .firstPage(limit: 10))
    let page2 = try await fetch(reader, window: .after(cursor(page1), limit: 10))
    let page3 = try await fetch(reader, window: .after(cursor(page2), limit: 10))

    #expect(page1.allEntryIDs.count == 10)
    #expect(page2.allEntryIDs.count == 10)
    #expect(page3.allEntryIDs.count == 5)
    #expect(
      page1.allEntryIDs + page2.allEntryIDs + page3.allEntryIDs == unbounded.allEntryIDs)
    #expect(page1.hasMore && page2.hasMore && !page3.hasMore)
    #expect(!unbounded.hasMore)
  }

  /// A sync page landing NEWER rows must not shift an existing page seam:
  /// `after(C)` still returns exactly the rows below C, and the whole-window
  /// `atOrAbove(C)` refresh returns inserts + the old window with no
  /// duplicate and no skip.
  @Test
  func insertAboveDoesNotShiftPages() async throws {
    let specs = (1...15).map { RowSpec(id: 1000 + $0, age: $0 * 60) }
    let (writer, reader) = try await makeSeededPair(specs)
    let page1 = try await fetch(reader, window: .firstPage(limit: 10))
    let seam = try cursor(page1)
    let belowBefore = try await fetch(reader, window: .after(seam, limit: 10))

    // Five NEWER rows land above everything (negative age = after base).
    let inserts = (1...5).map { RowSpec(id: 2000 + $0, age: -$0 * 60) }
    let insertEntries = try inserts.map { spec in
      try FeedbinFixtures.entry(
        id: spec.id, title: "Story \(spec.id)",
        published: Self.publishedString(secondsBeforeBase: spec.age))
    }
    _ = try await writer.persistEntries(insertEntries, unreadIDs: Set(inserts.map(\.id)))
    for spec in inserts {
      try await writer.applyClassification(
        entryID: spec.id,
        result: ClassificationResult(entryID: spec.id, categoryLabel: "tech", confidence: 0.9))
    }

    let belowAfter = try await fetch(reader, window: .after(seam, limit: 10))
    let refreshed = try await fetch(reader, window: .atOrAbove(seam))

    #expect(rowIDs(belowAfter) == rowIDs(belowBefore))
    #expect(rowIDs(refreshed) == [2005, 2004, 2003, 2002, 2001] + rowIDs(page1))
    #expect(refreshed.hasMore)
  }

  /// The cursor row leaving the unread filter (mark-read) must not skip or
  /// duplicate rows below the seam — the `after` clause orders on the
  /// immutable `(publishedAt, feedbinEntryID)` key, not on row membership.
  @Test
  func cursorRowFlipsReadStillTiles() async throws {
    let specs = (1...15).map { RowSpec(id: 1000 + $0, age: $0 * 60) }
    let (writer, reader) = try await makeSeededPair(specs)
    let page1 = try await fetch(reader, window: .firstPage(limit: 10))
    let seam = try cursor(page1)
    let belowBefore = try await fetch(reader, window: .after(seam, limit: 10))

    try await writer.markEntriesRead(feedbinEntryIDs: [seam.feedbinEntryID])

    let belowAfter = try await fetch(reader, window: .after(seam, limit: 10))
    #expect(rowIDs(belowAfter) == rowIDs(belowBefore))
    // The whole-window refresh drops the flipped row in place (9 rows) —
    // membership changed, the seam did not.
    let refreshed = try await fetch(reader, window: .atOrAbove(seam))
    #expect(rowIDs(refreshed) == Array(rowIDs(page1).dropLast()))
  }

  // MARK: - hasMore exactness

  @Test
  func hasMoreIsExactAtThePageBoundary() async throws {
    // Exactly K rows → no false positive.
    let (_, readerAtK) = try await makeSeededPair(
      (1...10).map { RowSpec(id: 1000 + $0, age: $0 * 60) })
    let exactlyFull = try await fetch(readerAtK, window: .firstPage(limit: 10))
    #expect(exactlyFull.allEntryIDs.count == 10)
    #expect(!exactlyFull.hasMore)

    // K+1 rows → true, and the follow-up page is the single remaining row.
    let (_, readerPastK) = try await makeSeededPair(
      (1...11).map { RowSpec(id: 1000 + $0, age: $0 * 60) })
    let full = try await fetch(readerPastK, window: .firstPage(limit: 10))
    #expect(full.allEntryIDs.count == 10)
    #expect(full.hasMore)
    let lastPage = try await fetch(readerPastK, window: .after(cursor(full), limit: 10))
    #expect(lastPage.allEntryIDs.count == 1)
    #expect(!lastPage.hasMore)
  }

  @Test
  func emptyCategoryFirstPageResolvesEmpty() async throws {
    let (_, reader) = try await makeSeededPair([])
    let result = try await fetch(reader, window: .firstPage(limit: 10))
    #expect(result.sections.isEmpty)
    #expect(!result.hasMore)
  }

  // MARK: - Pin coverage

  /// A pinned (selected) row deeper than the first page grows the page to the
  /// pin's sort position — selection and anchor-restore never point outside
  /// the loaded window.
  @Test
  func pinCoverageGrowsFirstPageToThePinnedRow() async throws {
    // 30 unread rows one minute apart; one READ row pinned between ages 24
    // and 25 → sort position 25 among the eligible (unread OR pinned) set.
    var specs = (1...30).map { RowSpec(id: 1000 + $0, age: $0 * 60) }
    let pinnedID = 3001
    specs.append(RowSpec(id: pinnedID, age: 24 * 60 + 30, read: true))
    let (_, reader) = try await makeSeededPair(specs)

    let result = try await fetch(reader, window: .firstPage(limit: 10), pinned: pinnedID)

    #expect(result.allEntryIDs.count == 25)
    #expect(rowIDs(result).contains(pinnedID))
    #expect(rowIDs(result).last == pinnedID)
    #expect(result.hasMore)
  }
}
