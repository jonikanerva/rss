import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - fetchEntrySections paging (issue #151)

/// Integration pins for the row cap: the page is always the canonical prefix
/// of the sorted result, the window grows to cover the pin, growth is a
/// fresh atomic refetch (da rider 2), and the unpaged path is unchanged.
/// `.serialized` for intra-suite ordering only; the cross-suite coordinator
/// cap is `make test`'s serial run (`STACK.md § 14`).
@Suite("DataReader paging", .serialized)
struct DataReaderPagingTests {
  private static let totalRows = 250
  private static let baseID = 1000

  /// Writer + reader over one in-memory container with `totalRows` classified
  /// unread rows in category "apple". The fixture publish date is shared, so
  /// canonical order is the deterministic `feedbinEntryID DESC` — the row at
  /// 1-based position P has id `baseID + totalRows − P`.
  private func makePagedFixture() async throws -> (DataWriter, DataReader) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple", sortOrder: 0)
    let entries = try (0..<Self.totalRows).map {
      try FeedbinFixtures.entry(id: Self.baseID + $0, title: "Row \($0)")
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))
    for entry in entries {
      try await writer.applyClassification(
        entryID: entry.id,
        result: ClassificationResult(entryID: entry.id, categoryLabel: "apple", confidence: 0.9))
    }
    return (writer, reader)
  }

  private func page(
    limit: Int, previous: [PersistentIdentifier] = []
  ) -> EntryListPageRequest {
    EntryListPageRequest(limit: limit, appendTriggerMargin: 20, previousVisibleIDs: previous)
  }

  @Test("Capped fetch returns the canonical first page")
  func cappedFetchReturnsCanonicalPrefix() async throws {
    let (_, reader) = try await makePagedFixture()
    let unpaged = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    let paged = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      paging: page(limit: 100))
    #expect(paged.allEntryIDs.count == 100)
    // The page IS the prefix of the unpaged canonical order — never a
    // reorder (`VISION.md → Core Principles`).
    #expect(paged.allEntryIDs == Array(unpaged.allEntryIDs.prefix(100)))
    #expect(paged.hasMore)
    #expect(paged.effectiveLimit == 100)
    // Trigger row sits `margin` rows before the window end.
    #expect(paged.appendTriggerID == paged.allEntryIDs[80])
    #expect(!paged.isPrefixExtension)
  }

  @Test("Pin beyond the window grows the fetch to cover it")
  func pinCoverageGrowsTheWindow() async throws {
    // Position 180 (1-based) → id baseID + totalRows − 180.
    let pinnedID = Self.baseID + Self.totalRows - 180
    let (_, reader) = try await makePagedFixture()
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: pinnedID, paging: page(limit: 100))
    #expect((result.effectiveLimit ?? 0) >= 180)
    #expect(result.allEntryIDs.count == result.effectiveLimit)
    // The pinned row is inside the grown window, and the window is still the
    // canonical prefix — chronology continuous, no out-of-band union.
    let unpaged = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: pinnedID)
    #expect(result.allEntryIDs == Array(unpaged.allEntryIDs.prefix(result.allEntryIDs.count)))
    #expect(result.sections.flatMap(\.rows).contains { $0.feedbinEntryID == pinnedID })
  }

  @Test("Growing past the store total settles hasMore false")
  func grownWindowPastTotalSettles() async throws {
    let (_, reader) = try await makePagedFixture()
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      paging: page(limit: 100))
    let grown = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      paging: page(limit: 300, previous: first.allEntryIDs))
    #expect(grown.allEntryIDs.count == Self.totalRows)
    #expect(!grown.hasMore)
    #expect(grown.appendTriggerID == nil)
    // Tail growth: the previous window is a strict prefix → the view skips
    // the anchor-restore scroll.
    #expect(grown.isPrefixExtension)
  }

  @Test("Grown window reflects writes landed between fetches (refetch contract)")
  func grownWindowIsCommittedTruth() async throws {
    // da rider 2: growth must be a fresh atomic refetch — a row marked read
    // between the first page and the grow must NOT surface in the appended
    // window as stale-unread; it leaves the unread membership entirely.
    let readID = Self.baseID + Self.totalRows - 150  // position 150, beyond page 1
    let (writer, reader) = try await makePagedFixture()
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      paging: page(limit: 100))
    #expect(first.allEntryIDs.count == 100)
    try await writer.markEntriesRead(feedbinEntryIDs: [readID])
    let grown = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      paging: page(limit: 300, previous: first.allEntryIDs))
    #expect(grown.allEntryIDs.count == Self.totalRows - 1)
    #expect(!grown.sections.flatMap(\.rows).contains { $0.feedbinEntryID == readID })
    #expect(!grown.renderedUnreadFeedbinEntryIDs.contains(readID))
  }

  @Test("Unpaged fetch keeps legacy outputs")
  func unpagedFetchHasNoPagingOutputs() async throws {
    let (_, reader) = try await makePagedFixture()
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    #expect(result.allEntryIDs.count == Self.totalRows)
    #expect(result.effectiveLimit == nil)
    #expect(!result.hasMore)
    #expect(result.appendTriggerID == nil)
    #expect(!result.isPrefixExtension)
  }
}
