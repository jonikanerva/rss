import Foundation
import Testing

@testable import Feeder

// MARK: - stripHTMLToPlainText

struct HTMLStrippingTests {
  @Test
  func removesTags() {
    #expect(stripHTMLToPlainText("<p>Hello <b>world</b></p>") == "Hello world")
  }

  @Test
  func decodesEntities() {
    #expect(stripHTMLToPlainText("Tom &amp; Jerry &lt;3&gt;") == "Tom & Jerry <3>")
  }

  @Test
  func handlesEmptyString() {
    #expect(stripHTMLToPlainText("") == "")
  }

  @Test
  func decodesQuotEntities() {
    #expect(stripHTMLToPlainText("&quot;hello&quot;") == "\"hello\"")
  }

  @Test
  func decodesApostrophe() {
    #expect(stripHTMLToPlainText("it&#39;s") == "it's")
  }

  @Test
  func decodesNbsp() {
    #expect(stripHTMLToPlainText("hello&nbsp;world") == "hello world")
  }

  @Test
  func collapsesWhitespace() {
    #expect(stripHTMLToPlainText("<p>hello</p>  <p>world</p>") == "hello world")
  }

  @Test
  func handlesNestedTags() {
    #expect(stripHTMLToPlainText("<div><p><em><strong>deep</strong></em></p></div>") == "deep")
  }

  @Test
  func plainTextPassthrough() {
    #expect(stripHTMLToPlainText("no tags here") == "no tags here")
  }
}

// MARK: - formatEntryDate

struct DateFormattingTests {
  @Test
  func todayShowsTodayPrefix() {
    let formatted = formatEntryDate(Date())
    #expect(formatted.hasPrefix("Today,"))
  }

  @Test
  func yesterdayShowsYesterdayPrefix() {
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    let formatted = formatEntryDate(yesterday)
    #expect(formatted.hasPrefix("Yesterday,"))
  }

  @Test
  func olderDateShowsWeekday() {
    let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
    let formatted = formatEntryDate(fiveDaysAgo)
    #expect(!formatted.hasPrefix("Today,"))
    #expect(!formatted.hasPrefix("Yesterday,"))
    // Should start with a weekday name
    #expect(formatted.contains(","))
  }
}

// MARK: - ordinalSuffix

struct OrdinalSuffixTests {
  @Test
  func firstSecondThirdUseStNdRd() {
    #expect(ordinalSuffix(forDay: 1) == "st")
    #expect(ordinalSuffix(forDay: 2) == "nd")
    #expect(ordinalSuffix(forDay: 3) == "rd")
  }

  @Test
  func fourthUsesTh() {
    #expect(ordinalSuffix(forDay: 4) == "th")
  }

  @Test
  func teensAlwaysUseTh() {
    #expect(ordinalSuffix(forDay: 11) == "th")
    #expect(ordinalSuffix(forDay: 12) == "th")
    #expect(ordinalSuffix(forDay: 13) == "th")
  }

  @Test
  func twentyFirstSecondThirdUseStNdRd() {
    #expect(ordinalSuffix(forDay: 21) == "st")
    #expect(ordinalSuffix(forDay: 22) == "nd")
    #expect(ordinalSuffix(forDay: 23) == "rd")
  }

  @Test
  func endOfMonthUsesTh() {
    #expect(ordinalSuffix(forDay: 30) == "th")
    #expect(ordinalSuffix(forDay: 31) == "st")
  }
}

// MARK: - formatEntryTime

struct EntryTimeFormattingTests {
  /// Build a `Date` at the given local wall-clock hour/minute for a fixed calendar day.
  /// Using `Calendar.current` on both sides keeps the test independent of the host timezone.
  private func date(hour: Int, minute: Int) throws -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 4
    components.day = 19
    components.hour = hour
    components.minute = minute
    return try #require(Calendar.current.date(from: components))
  }

  @Test
  func morningTimeIsZeroPadded() throws {
    try #expect(formatEntryTime(date(hour: 9, minute: 4)) == "09.04")
  }

  @Test
  func eveningTimeUsesTwentyFourHourClock() throws {
    try #expect(formatEntryTime(date(hour: 21, minute: 24)) == "21.24")
  }

  @Test
  func midnightIsDoubleZero() throws {
    try #expect(formatEntryTime(date(hour: 0, minute: 0)) == "00.00")
  }

  @Test
  func oneMinuteBeforeMidnight() throws {
    try #expect(formatEntryTime(date(hour: 23, minute: 59)) == "23.59")
  }

  @Test
  func noonIsTwelveHundred() throws {
    try #expect(formatEntryTime(date(hour: 12, minute: 0)) == "12.00")
  }
}
