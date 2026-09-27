import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - entryListSectionLabel

struct EntryListSectionLabelTests {
  /// Every boundary comes from `startOfDay`, the day interval, and ±1 s, never
  /// from a fixed day length, so the checks hold in every time zone.
  @Test
  func labelsFollowTheDayBoundariesOfNow() throws {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
    let tomorrowStart = try #require(calendar.dateInterval(of: .day, for: todayStart)).end
    let todayEnd = tomorrowStart.addingTimeInterval(-1)
    let yesterdayEnd = todayStart.addingTimeInterval(-1)
    let yesterdayStart = calendar.startOfDay(for: yesterdayEnd)
    let dayBeforeYesterdayEnd = yesterdayStart.addingTimeInterval(-1)

    for now in [todayStart, todayEnd] {
      #expect(entryListSectionLabel(for: todayStart, now: now) == "Today", "now \(now)")
      #expect(entryListSectionLabel(for: todayEnd, now: now) == "Today", "now \(now)")
      #expect(entryListSectionLabel(for: yesterdayStart, now: now) == "Yesterday", "now \(now)")
      #expect(entryListSectionLabel(for: yesterdayEnd, now: now) == "Yesterday", "now \(now)")
      for date in [dayBeforeYesterdayEnd, tomorrowStart] {
        let label = entryListSectionLabel(for: date, now: now)
        #expect(label.contains("\(calendar.component(.day, from: date))."), "now \(now) label \(label)")
        #expect(label.contains(date.formatted(.dateTime.year())), "now \(now) label \(label)")
      }
    }
  }

  @Test
  func olderDateContainsWeekdayDayMonthYear() {
    let olderDate = Date(timeIntervalSince1970: 1_750_000_000)
    let now = Date(timeIntervalSince1970: 1_760_000_000)
    let label = entryListSectionLabel(for: Calendar.current.startOfDay(for: olderDate), now: now)
    #expect(label != "Today" && label != "Yesterday")
    let day = Calendar.current.component(.day, from: olderDate)
    #expect(label.contains("\(day)."))
    let yearString = olderDate.formatted(.dateTime.year())
    #expect(label.contains(yearString))
  }
}

// MARK: - groupRowsByDay

/// Pins the day bucketing and the section labels of `groupRowsByDay` against a
/// fixed `now`. Grouping follows the user's local calendar, like the labels it
/// feeds.
@MainActor
struct GroupRowsByDayTests {
  private static let base = Date(timeIntervalSince1970: 1_750_000_000)

  /// Anchors at local noon, so all three dates fall on one local day at any
  /// time of the run and in any host zone. Never offset `base` by hours instead.
  private static func sameDayPublishDates(on day: Date) throws -> [Date] {
    let noon = try #require(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day))
    return [noon, noon.addingTimeInterval(-3600), noon.addingTimeInterval(-7200)]
  }

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
        url: "https://example.com/\(offset)",
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
    #expect(groupRowsByDay([], now: Self.base).isEmpty)
  }

  @Test
  func rowsAllOnSameDayProduceOneSection() throws {
    let rows = try Self.makeRows(publishDates: Self.sameDayPublishDates(on: Self.base))
    let sections = groupRowsByDay(rows, now: Self.base)
    #expect(sections.count == 1)
    #expect(sections[0].rows.count == 3)
    #expect(sections[0].label == "Today")
  }

  @Test
  func rowsSpanningTwoDaysProduceTwoSections() throws {
    let today = try Self.sameDayPublishDates(on: Self.base)
    let yesterday = try Self.sameDayPublishDates(on: Calendar.current.startOfDay(for: Self.base).addingTimeInterval(-1))
    let rows = try Self.makeRows(publishDates: [today[0], yesterday[0], yesterday[1]])
    let sections = groupRowsByDay(rows, now: Self.base)
    #expect(sections.count == 2)
    #expect(sections[0].label == "Today")
    #expect(sections[0].rows.count == 1)
    #expect(sections[1].label == "Yesterday")
    #expect(sections[1].rows.count == 2)
  }

  @Test
  func sectionIDsAreStartOfDay() throws {
    let rows = try Self.makeRows(publishDates: [Self.base])
    let sections = groupRowsByDay(rows, now: Self.base)
    let expectedStartOfDay = Calendar.current.startOfDay(for: Self.base)
    #expect(sections[0].id == expectedStartOfDay)
  }

  @Test
  func rowOrderIsPreservedWithinSections() throws {
    let rows = try Self.makeRows(publishDates: Self.sameDayPublishDates(on: Self.base))
    let sections = groupRowsByDay(rows, now: Self.base)
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
