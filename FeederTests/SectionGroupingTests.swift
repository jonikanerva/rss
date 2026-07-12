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

// MARK: - groupRowsByDay

/// The grouping moved from `@Model Entry` input (`groupEntriesByDay` in
/// `DataWriter`) to pure `EntryRowDTO` input (issue #148). The
/// `Calendar.current` / `startOfDay` day-bucketing and the
/// `entryListSectionLabel` labels are UNCHANGED through the move — these
/// tests carry over the same expectations against the same wall-clock
/// scenarios to pin that.
@MainActor
struct GroupRowsByDayTests {
  /// Builds row DTOs with the given publish dates. Only the
  /// `PersistentIdentifier` needs a store (it has no public initializer);
  /// every field the grouping reads is set right here.
  private static func makeRows(publishDates: [Date]) throws -> [EntryRowDTO] {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let context = ModelContext(container)
    return publishDates.enumerated().map { offset, date in
      let entry = Entry(
        feedbinEntryID: 1000 + offset, title: "Entry \(offset)", author: nil,
        url: "https://example.com/\(offset)", content: nil, summary: nil,
        extractedContentURL: nil, publishedAt: date, createdAt: date
      )
      context.insert(entry)
      return EntryRowDTO(
        persistentID: entry.persistentModelID,
        feedbinEntryID: 1000 + offset,
        title: "Entry \(offset)",
        formattedPublishedTime: "09.30",
        displayDomain: "example.com",
        excerpt: "Excerpt \(offset)",
        isRead: false,
        publishedAt: date,
        feedFeedbinID: 1,
        feedInitial: "E"
      )
    }
  }

  @Test
  func emptyInputReturnsEmpty() {
    #expect(groupRowsByDay([]).isEmpty)
  }

  @Test
  func rowsAllOnSameDayProduceOneSection() throws {
    let now = Date()
    let rows = try Self.makeRows(publishDates: [
      now, now.addingTimeInterval(-3600), now.addingTimeInterval(-7200),
    ])
    let sections = groupRowsByDay(rows)
    #expect(sections.count == 1)
    #expect(sections[0].rows.count == 3)
    #expect(sections[0].label == "Today")
  }

  @Test
  func rowsSpanningTwoDaysProduceTwoSections() throws {
    let today = Date()
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let rows = try Self.makeRows(publishDates: [today, yesterday, yesterday])
    let sections = groupRowsByDay(rows)
    #expect(sections.count == 2)
    #expect(sections[0].label == "Today")
    #expect(sections[0].rows.count == 1)
    #expect(sections[1].label == "Yesterday")
    #expect(sections[1].rows.count == 2)
  }

  @Test
  func sectionIDsAreStartOfDay() throws {
    let now = Date()
    let rows = try Self.makeRows(publishDates: [now])
    let sections = groupRowsByDay(rows)
    let expectedStartOfDay = Calendar.current.startOfDay(for: now)
    #expect(sections[0].id == expectedStartOfDay)
  }

  @Test
  func rowOrderIsPreservedWithinSections() throws {
    let now = Date()
    let rows = try Self.makeRows(publishDates: [
      now, now.addingTimeInterval(-3600), now.addingTimeInterval(-7200),
    ])
    let sections = groupRowsByDay(rows)
    #expect(sections[0].rows.map(\.feedbinEntryID) == rows.map(\.feedbinEntryID))
  }
}

// MARK: - rowExcerpt

struct RowExcerptTests {
  @Test
  func summaryIsPreferredOverPlainText() {
    #expect(rowExcerpt(summaryPlainText: "Summary.", plainText: "Body.") == "Summary.")
  }

  @Test
  func emptySummaryFallsBackToPlainText() {
    #expect(rowExcerpt(summaryPlainText: "", plainText: "Body.") == "Body.")
  }

  @Test
  func bothEmptyYieldsEmpty() {
    #expect(rowExcerpt(summaryPlainText: "", plainText: "").isEmpty)
  }

  @Test
  func whitespaceIsTrimmed() {
    #expect(rowExcerpt(summaryPlainText: "  Summary.\n", plainText: "") == "Summary.")
  }

  @Test
  func longFallbackIsCappedAt500Characters() {
    let body = String(repeating: "a", count: 2000)
    let excerpt = rowExcerpt(summaryPlainText: "", plainText: body)
    #expect(excerpt.count == 500)
    #expect(body.hasPrefix(excerpt))
  }

  @Test
  func capAppliesAfterTrimming() {
    let body = "   " + String(repeating: "b", count: 600)
    let excerpt = rowExcerpt(summaryPlainText: "", plainText: body)
    #expect(excerpt.count == 500)
    #expect(excerpt.first == "b")
  }
}

// MARK: - feedInitial

struct FeedInitialTests {
  @Test
  func firstLetterUppercased() {
    #expect(feedInitial(from: "mobilegamer.biz") == "M")
  }

  @Test
  func nilFeedTitleYieldsQuestionMark() {
    #expect(feedInitial(from: nil) == "?")
  }

  @Test
  func emptyFeedTitleYieldsQuestionMark() {
    #expect(feedInitial(from: "") == "?")
  }
}
