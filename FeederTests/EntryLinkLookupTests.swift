import Foundation
import SwiftData
import Testing

@testable import Feeder

/// The link lookup behind the article-list context menu. `PersistentIdentifier`
/// has no public initializer, so the fixtures take identifiers from unsaved rows
/// in an in-memory container. The lookup never reads the store. `@MainActor`
/// only because the minting uses the main context.
@MainActor
@Suite("Entry link lookup (pure)")
struct EntryLinkLookupTests {
  private let container: ModelContainer
  private let dayOne: Date
  private let dayTwo: Date

  init() throws {
    container = try DataWriterTestSupport.makeInMemoryContainer()
    let base = Date(timeIntervalSince1970: 1_750_000_000)
    dayOne = Calendar.current.startOfDay(for: base)
    dayTwo = Calendar.current.startOfDay(for: base.addingTimeInterval(-86_400))
  }

  /// A row DTO with a real `PersistentIdentifier` and the given stored link.
  private func row(id: Int, publishedAt: Date, url: String? = nil) -> EntryRowDTO {
    let link = url ?? "https://example.com/articles/\(id)"
    let entry = Entry(
      feedbinEntryID: id, title: "Row \(id)", author: nil, url: link,
      content: nil, summary: nil, extractedContentURL: nil,
      publishedAt: publishedAt, createdAt: publishedAt)
    container.mainContext.insert(entry)
    return EntryRowDTO(
      persistentID: entry.persistentModelID,
      feedbinEntryID: id,
      title: "Row \(id)",
      url: link,
      formattedPublishedTime: "",
      displayDomain: nil,
      excerpt: "",
      isRead: false,
      publishedAt: publishedAt,
      feedFeedbinID: nil,
      feedInitial: "R"
    )
  }

  /// `count` rows one second apart, newest first, with IDs from `firstID`
  /// upwards.
  private func rows(firstID: Int, count: Int, newest: Date) -> [EntryRowDTO] {
    (0..<count).map { offset in
      row(id: firstID + offset, publishedAt: newest.addingTimeInterval(-Double(offset)))
    }
  }

  private func window(_ sections: [EntryListSection], hasMore: Bool) -> EntryListFetchResult {
    let rows = sections.flatMap(\.rows)
    return EntryListFetchResult(
      sections: sections,
      allEntryIDs: rows.map(\.persistentID),
      distinctFeedIDs: [],
      renderedUnreadFeedbinEntryIDs: Set(rows.map(\.feedbinEntryID)),
      hasMore: hasMore
    )
  }

  @Test("one loaded ID gives the link of that row")
  func oneLoadedIDGivesItsLink() {
    let first = row(id: 1, publishedAt: dayOne.addingTimeInterval(900))
    let second = row(id: 2, publishedAt: dayOne.addingTimeInterval(600))
    let sections = [EntryListSection(id: dayOne, label: "Day", rows: [first, second])]

    let url = entryLinkURL(for: [second.persistentID], in: sections)

    #expect(url == URL(string: "https://example.com/articles/2"))
  }

  @Test("a row that an append placed at index 100 or later gives its link")
  func appendedRowGivesItsLink() throws {
    let noon: TimeInterval = 43_200
    let firstPage = window(
      [
        EntryListSection(
          id: dayOne, label: "Day one",
          rows: rows(firstID: 1, count: 100, newest: dayOne.addingTimeInterval(noon)))
      ],
      hasMore: true)
    let sameDay = rows(firstID: 101, count: 10, newest: dayOne.addingTimeInterval(noon - 3_600))
    let olderDay = rows(firstID: 111, count: 10, newest: dayTwo.addingTimeInterval(noon))
    let page = window(
      [
        EntryListSection(id: dayOne, label: "Day one", rows: sameDay),
        EntryListSection(id: dayTwo, label: "Day two", rows: olderDay),
      ],
      hasMore: false)

    let merged = firstPage.appending(page)
    let loadedRows = merged.sections.flatMap(\.rows)
    try #require(loadedRows.count == 120)

    // Index 105 extends the first section; index 115 sits in the appended one.
    for index in [105, 115] {
      let target = loadedRows[index]
      #expect(
        entryLinkURL(for: [target.persistentID], in: merged.sections)
          == URL(string: "https://example.com/articles/\(target.feedbinEntryID)"),
        "index \(index)")
    }
  }

  @Test("an empty set gives nil")
  func emptySetGivesNil() {
    let sections = [
      EntryListSection(id: dayOne, label: "Day", rows: [row(id: 1, publishedAt: dayOne)])
    ]

    #expect(entryLinkURL(for: [], in: sections) == nil)
  }

  @Test("an ID that is not loaded gives nil")
  func unknownIDGivesNil() {
    let loaded = row(id: 1, publishedAt: dayOne.addingTimeInterval(600))
    let removed = row(id: 2, publishedAt: dayOne.addingTimeInterval(300))
    let sections = [EntryListSection(id: dayOne, label: "Day", rows: [loaded])]

    #expect(entryLinkURL(for: [removed.persistentID], in: sections) == nil)
  }

  @Test("two loaded IDs give nil")
  func twoLoadedIDsGiveNil() {
    let first = row(id: 1, publishedAt: dayOne.addingTimeInterval(900))
    let second = row(id: 2, publishedAt: dayOne.addingTimeInterval(600))
    let sections = [EntryListSection(id: dayOne, label: "Day", rows: [first, second])]

    #expect(entryLinkURL(for: [first.persistentID, second.persistentID], in: sections) == nil)
  }

  @Test("a row with an empty stored link gives nil")
  func emptyStoredLinkGivesNil() {
    let linkless = row(id: 1, publishedAt: dayOne, url: "")
    let sections = [EntryListSection(id: dayOne, label: "Day", rows: [linkless])]

    #expect(entryLinkURL(for: [linkless.persistentID], in: sections) == nil)
    #expect(entryLinkURL(from: "") == nil)
  }
}
