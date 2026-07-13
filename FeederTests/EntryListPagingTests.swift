import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Pure paging math + window merge (issue #155): cursor derivation, the
/// append-trigger index, pin-coverage limit growth, the refresh-empty
/// fallback rule, and `EntryListFetchResult.appending`'s section merge with
/// its dedupe guard. `PersistentIdentifier` has no public initializer, so row
/// fixtures mint identifiers by inserting throwaway `Entry` rows into an
/// in-memory container — the store is never fetched; the functions under
/// test are pure. `@MainActor` only because fixture minting touches
/// `container.mainContext`.
@MainActor
@Suite("EntryListPaging (pure)")
struct EntryListPagingTests {
  private let container: ModelContainer
  private let dayOne: Date
  private let dayTwo: Date

  init() throws {
    container = try DataWriterTestSupport.makeInMemoryContainer()
    // Two distinct calendar days, resolved through the SAME
    // `Calendar.current.startOfDay` bucketing `groupRowsByDay` uses, so
    // section ids match production regardless of the host timezone.
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    dayOne = Calendar.current.startOfDay(for: base)
    dayTwo = Calendar.current.startOfDay(for: base.addingTimeInterval(-86_400))
  }

  /// Mint a row DTO with a REAL `PersistentIdentifier` (temporary id of an
  /// inserted, unsaved model — identity is all the paging math reads).
  private func row(
    id: Int, publishedAt: Date, isRead: Bool = false, feedID: Int? = nil
  ) -> EntryRowDTO {
    let entry = Entry(
      feedbinEntryID: id, title: "Row \(id)", author: nil, url: "https://example.com/\(id)",
      content: nil, summary: nil, extractedContentURL: nil,
      publishedAt: publishedAt, createdAt: publishedAt)
    container.mainContext.insert(entry)
    return EntryRowDTO(
      persistentID: entry.persistentModelID,
      feedbinEntryID: id,
      title: "Row \(id)",
      formattedPublishedTime: "",
      displayDomain: nil,
      excerpt: "",
      isRead: isRead,
      publishedAt: publishedAt,
      feedFeedbinID: feedID,
      feedInitial: "R"
    )
  }

  private func section(day: Date, rows: [EntryRowDTO]) -> EntryListSection {
    EntryListSection(id: day, label: "Day", rows: rows)
  }

  private func result(sections: [EntryListSection], hasMore: Bool) -> EntryListFetchResult {
    let rows = sections.flatMap(\.rows)
    return EntryListFetchResult(
      sections: sections,
      allEntryIDs: rows.map(\.persistentID),
      distinctFeedIDs: Set(rows.compactMap(\.feedFeedbinID)),
      renderedUnreadFeedbinEntryIDs: Set(rows.filter { !$0.isRead }.map(\.feedbinEntryID)),
      hasMore: hasMore
    )
  }

  // MARK: - Cursor derivation

  @Test
  func cursorDerivesFromLastRowOfLastSection() {
    let rows1 = [row(id: 1, publishedAt: dayOne.addingTimeInterval(600))]
    let rows2 = [
      row(id: 2, publishedAt: dayTwo.addingTimeInterval(900)),
      row(id: 3, publishedAt: dayTwo.addingTimeInterval(300)),
    ]
    let sections = [section(day: dayOne, rows: rows1), section(day: dayTwo, rows: rows2)]

    let cursor = entryListCursor(of: sections)

    #expect(
      cursor
        == EntryListCursor(
          publishedAt: dayTwo.addingTimeInterval(300), feedbinEntryID: 3))
  }

  @Test
  func cursorIsNilForEmptyWindow() {
    #expect(entryListCursor(of: []) == nil)
  }

  // MARK: - Append trigger index

  @Test
  func appendTriggerIndexMath() {
    let cases: [(fetched: Int, margin: Int, expected: Int?)] = [
      (fetched: 0, margin: 20, expected: nil),
      (fetched: 1, margin: 20, expected: 0),
      (fetched: 5, margin: 20, expected: 0),
      (fetched: 20, margin: 20, expected: 0),
      (fetched: 21, margin: 20, expected: 1),
      (fetched: 100, margin: 20, expected: 80),
    ]
    for testCase in cases {
      #expect(
        appendTriggerIndex(fetchedCount: testCase.fetched, margin: testCase.margin)
          == testCase.expected,
        "fetched=\(testCase.fetched) margin=\(testCase.margin)")
    }
  }

  // MARK: - Pin coverage limit

  @Test
  func effectiveRowLimitNeverShrinksBelowRequest() {
    #expect(effectiveRowLimit(requested: 100, pinPosition: 25) == 100)
    #expect(effectiveRowLimit(requested: 100, pinPosition: 100) == 100)
    #expect(effectiveRowLimit(requested: 100, pinPosition: 250) == 250)
  }

  // MARK: - Refresh-empty fallback rule

  @Test
  func refreshFallbackFiresOnlyForEmptyAtOrAboveResults() {
    let cursor = EntryListCursor(publishedAt: dayOne, feedbinEntryID: 1)
    let empty = EntryListFetchResult.empty
    let nonEmpty = result(
      sections: [section(day: dayOne, rows: [row(id: 1, publishedAt: dayOne)])], hasMore: false)

    #expect(refreshRequiresFirstPageFallback(window: .atOrAbove(cursor), result: empty))
    #expect(!refreshRequiresFirstPageFallback(window: .atOrAbove(cursor), result: nonEmpty))
    #expect(!refreshRequiresFirstPageFallback(window: .firstPage(limit: 100), result: empty))
    #expect(!refreshRequiresFirstPageFallback(window: .after(cursor, limit: 100), result: empty))
  }

  // MARK: - appending(): section merge

  @Test
  func appendingExtendsSameDaySectionUnderItsExistingID() {
    let a = row(id: 1, publishedAt: dayOne.addingTimeInterval(900))
    let b = row(id: 2, publishedAt: dayOne.addingTimeInterval(600))
    let c = row(id: 3, publishedAt: dayOne.addingTimeInterval(300))
    let window = result(sections: [section(day: dayOne, rows: [a, b])], hasMore: true)
    let page = result(sections: [section(day: dayOne, rows: [c])], hasMore: false)

    let merged = window.appending(page)

    // One section, SAME id — the List diff is a pure tail insertion.
    #expect(merged.sections.count == 1)
    #expect(merged.sections.map(\.id) == [dayOne])
    #expect(merged.sections[0].rows.map(\.feedbinEntryID) == [1, 2, 3])
    #expect(merged.allEntryIDs == [a, b, c].map(\.persistentID))
    #expect(merged.hasMore == false)
  }

  @Test
  func appendingConcatenatesAcrossADayEdge() {
    let a = row(id: 1, publishedAt: dayOne.addingTimeInterval(900))
    let b = row(id: 2, publishedAt: dayTwo.addingTimeInterval(900))
    let window = result(sections: [section(day: dayOne, rows: [a])], hasMore: true)
    let page = result(sections: [section(day: dayTwo, rows: [b])], hasMore: true)

    let merged = window.appending(page)

    #expect(merged.sections.map(\.id) == [dayOne, dayTwo])
    #expect(merged.allEntryIDs == [a, b].map(\.persistentID))
    #expect(merged.hasMore == true)
  }

  @Test
  func appendingEmptyPageKeepsSectionsAndAdoptsHasMore() {
    let a = row(id: 1, publishedAt: dayOne)
    let window = result(sections: [section(day: dayOne, rows: [a])], hasMore: true)

    let merged = window.appending(.empty)

    #expect(merged.sections == window.sections)
    #expect(merged.allEntryIDs == window.allEntryIDs)
    #expect(merged.hasMore == false)
  }

  @Test
  func appendingUnionsAggregates() {
    let a = row(id: 1, publishedAt: dayOne.addingTimeInterval(900), isRead: true, feedID: 10)
    let b = row(id: 2, publishedAt: dayOne.addingTimeInterval(600), isRead: false, feedID: 20)
    let window = result(sections: [section(day: dayOne, rows: [a])], hasMore: true)
    let page = result(sections: [section(day: dayOne, rows: [b])], hasMore: true)

    let merged = window.appending(page)

    #expect(merged.distinctFeedIDs == [10, 20])
    #expect(merged.renderedUnreadFeedbinEntryIDs == [2])
  }

  /// Dedupe guard (issue #155): a page row whose `feedbinEntryID` already
  /// exists in the window is dropped — the belt-and-braces demotion of a
  /// `persistEntries` immutability-invariant violation to a non-event.
  @Test
  func appendingDropsRowsAlreadyInTheWindow() {
    let a = row(id: 1, publishedAt: dayOne.addingTimeInterval(900))
    let duplicateOfA = row(id: 1, publishedAt: dayOne.addingTimeInterval(600))
    let b = row(id: 2, publishedAt: dayOne.addingTimeInterval(300))
    let window = result(sections: [section(day: dayOne, rows: [a])], hasMore: true)
    let page = result(sections: [section(day: dayOne, rows: [duplicateOfA, b])], hasMore: false)

    let merged = window.appending(page)

    #expect(merged.sections[0].rows.map(\.feedbinEntryID) == [1, 2])
    #expect(merged.allEntryIDs == [a, b].map(\.persistentID))
    #expect(merged.hasMore == false)
  }

  @Test
  func appendingFullyDedupedPageStillAdoptsHasMore() {
    let a = row(id: 1, publishedAt: dayOne)
    let duplicateOfA = row(id: 1, publishedAt: dayOne)
    let window = result(sections: [section(day: dayOne, rows: [a])], hasMore: true)
    let page = result(sections: [section(day: dayOne, rows: [duplicateOfA])], hasMore: false)

    let merged = window.appending(page)

    #expect(merged.sections == window.sections)
    #expect(merged.hasMore == false)
  }
}
