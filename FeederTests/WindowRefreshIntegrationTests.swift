import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Data-level pins for the trust condition behind refresh suppression: a
/// refresh suppressed as a no-op must be provably unable to change the visible
/// window, so every case where the window does change must keep flowing through
/// the fetches the view consumes. It runs the production writer and reader on
/// one shared in-memory container; the serial unit-target run caps coordinator
/// pressure (`STACK.md § 14`), because `.serialized` orders tests within the
/// suite only.
@Suite("Window refresh integration", .serialized)
struct WindowRefreshIntegrationTests {
  private static let base = Date(timeIntervalSince1970: 1_750_000_000)

  private static func publishedString(secondsBeforeBase seconds: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: base.addingTimeInterval(-Double(seconds)))
  }

  /// Seed a feed plus the `tech` / `other` categories, persist the given
  /// rows (all unread), and classify each into its spec'd category.
  private func makeSeededPair(
    _ specs: [(id: Int, age: Int, category: String)]
  ) async throws -> (DataWriter, DataReader) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    try await writer.addCategory(
      label: "tech", displayName: "Tech", description: "Tech news", sortOrder: 0)
    try await writer.addCategory(
      label: "other", displayName: "Other", description: "Everything else", sortOrder: 1)
    let entries = try specs.map { spec in
      try FeedbinFixtures.entry(
        id: spec.id, title: "Story \(spec.id)",
        published: Self.publishedString(secondsBeforeBase: spec.age))
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(specs.map(\.id)))
    for spec in specs {
      try await writer.applyClassification(
        entryID: spec.id,
        result: ClassificationResult(entryID: spec.id, categoryLabel: spec.category))
    }
    return (writer, reader)
  }

  private func fetch(
    _ reader: DataReader, window: EntryListWindow
  ) async throws -> EntryListFetchResult {
    try await reader.fetchEntrySections(
      category: "tech", folder: nil, showRead: false,
      cutoffDate: .distantPast, pinnedFeedbinEntryID: nil, window: window)
  }

  /// Reclassification lands an older row below the loaded window's cursor. The
  /// whole-window refresh returns identical sections and flips `hasMore`, which
  /// re-arms the append trigger, so "the row must appear" holds as "the row
  /// becomes reachable". The view consumes that flag through its own guard
  /// branch for a sections-unchanged result.
  @Test
  func reclassificationBelowCursorFlipsOnlyHasMore() async throws {
    var specs = (1...5).map { (id: 1000 + $0, age: $0 * 60, category: "tech") }
    let olderID = 2001
    specs.append((id: olderID, age: 600, category: "other"))
    let (writer, reader) = try await makeSeededPair(specs)

    let window = try await fetch(reader, window: .firstPage(limit: 10))
    #expect(window.allEntryIDs.count == 5)
    #expect(!window.hasMore)
    let cursor = try #require(entryListCursor(of: window.sections))

    // The reclassification write: the older row moves INTO the visible axis,
    // strictly below the loaded window's bottom edge.
    try await writer.applyClassification(
      entryID: olderID,
      result: ClassificationResult(entryID: olderID, categoryLabel: "tech"))

    let refreshed = try await fetch(reader, window: .atOrAbove(cursor))
    #expect(refreshed.sections == window.sections)
    #expect(refreshed.hasMore)

    // Reachability: the re-armed append path returns the reclassified row.
    let nextPage = try await fetch(reader, window: .after(cursor, limit: 10))
    #expect(nextPage.sections.flatMap(\.rows).map(\.feedbinEntryID) == [olderID])
  }

  /// ux regression case 1: an EMPTY visible category gaining its FIRST row
  /// must surface it without user action. The view's refresh path fetches a
  /// first page when the window has no cursor; this pins the data shape that
  /// path consumes — empty before the write, one row after.
  @Test
  func emptyCategoryGainsItsFirstRow() async throws {
    let (writer, reader) = try await makeSeededPair(
      [(id: 3001, age: 60, category: "other")])

    let empty = try await fetch(reader, window: .firstPage(limit: 10))
    #expect(empty.sections.isEmpty)
    #expect(!empty.hasMore)
    #expect(entryListCursor(of: empty.sections) == nil)

    try await writer.applyClassification(
      entryID: 3001,
      result: ClassificationResult(entryID: 3001, categoryLabel: "tech"))

    let firstPage = try await fetch(reader, window: .firstPage(limit: 10))
    #expect(firstPage.sections.flatMap(\.rows).map(\.feedbinEntryID) == [3001])
    #expect(!firstPage.hasMore)
  }
}
