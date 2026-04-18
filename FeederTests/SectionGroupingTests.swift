import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - entryListSectionLabel

struct EntryListSectionLabelTests {
  @Test
  func todayReturnsToday() {
    let startOfToday = Calendar.current.startOfDay(for: Date())
    #expect(entryListSectionLabel(for: startOfToday) == "Today")
  }

  @Test
  func yesterdayReturnsYesterday() {
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    let startOfYesterday = Calendar.current.startOfDay(for: yesterday)
    #expect(entryListSectionLabel(for: startOfYesterday) == "Yesterday")
  }

  @Test
  func olderDateContainsWeekdayDayMonthYear() {
    let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
    let label = entryListSectionLabel(for: Calendar.current.startOfDay(for: fiveDaysAgo))
    #expect(label != "Today" && label != "Yesterday")
    let day = Calendar.current.component(.day, from: fiveDaysAgo)
    #expect(label.contains("\(day)."))
    let yearString = fiveDaysAgo.formatted(.dateTime.year())
    #expect(label.contains(yearString))
  }
}

// MARK: - groupEntriesByDay

@MainActor
struct GroupEntriesByDayTests {
  private static func makeContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: Entry.self, Feed.self, Category.self, Folder.self,
      configurations: config
    )
  }

  /// Inserts entries into a fresh context and returns them with valid `persistentModelID`s.
  private static func makeEntries(publishDates: [Date]) throws -> [Entry] {
    let container = try makeContainer()
    let context = ModelContext(container)
    var entries: [Entry] = []
    for (offset, date) in publishDates.enumerated() {
      let entry = Entry(
        feedbinEntryID: 1000 + offset, title: "Entry \(offset)", author: nil,
        url: "https://example.com/\(offset)", content: nil, summary: nil,
        extractedContentURL: nil, publishedAt: date, createdAt: date
      )
      context.insert(entry)
      entries.append(entry)
    }
    return entries
  }

  @Test
  func emptyInputReturnsEmpty() {
    #expect(groupEntriesByDay([]).isEmpty)
  }

  @Test
  func entriesAllOnSameDayProduceOneSection() throws {
    let now = Date()
    let entries = try Self.makeEntries(publishDates: [
      now, now.addingTimeInterval(-3600), now.addingTimeInterval(-7200),
    ])
    let sections = groupEntriesByDay(entries)
    #expect(sections.count == 1)
    #expect(sections[0].entryIDs.count == 3)
    #expect(sections[0].label == "Today")
  }

  @Test
  func entriesSpanningTwoDaysProduceTwoSections() throws {
    let today = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let entries = try Self.makeEntries(publishDates: [today, yesterday, yesterday])
    let sections = groupEntriesByDay(entries)
    #expect(sections.count == 2)
    #expect(sections[0].label == "Today")
    #expect(sections[0].entryIDs.count == 1)
    #expect(sections[1].label == "Yesterday")
    #expect(sections[1].entryIDs.count == 2)
  }

  @Test
  func sectionIDsAreStartOfDay() throws {
    let now = Date()
    let entries = try Self.makeEntries(publishDates: [now])
    let sections = groupEntriesByDay(entries)
    let expectedStartOfDay = Calendar.current.startOfDay(for: now)
    #expect(sections[0].id == expectedStartOfDay)
  }
}
