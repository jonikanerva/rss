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
