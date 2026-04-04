//
//  FeederTests.swift
//  FeederTests
//

import Foundation
import Testing

@testable import Feeder

// MARK: - Classification Instructions Tests (uses extracted buildClassificationInstructions)

struct ClassificationInstructionsTests {
  @Test
  func promptShowsFlatList() {
    let categories = [
      CategoryDefinition(label: "apple", description: "Apple news", folderLabel: "technology"),
      CategoryDefinition(label: "world", description: "World news"),
    ]
    let instructions = buildClassificationInstructions(from: categories)

    #expect(instructions.contains("- apple: Apple news"))
    #expect(instructions.contains("- world: World news"))
    // No indentation — flat list
    #expect(!instructions.contains("  - "))
  }

  @Test
  func emptyCategories() {
    let instructions = buildClassificationInstructions(from: [])
    #expect(instructions.contains("Categories:"))
  }

  @Test
  func instructionsContainSingleCategoryDirective() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech")
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(instructions.contains("Assign the single best matching category"))
  }

  @Test
  func instructionsIncludeUncategorized() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech")
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(instructions.contains("- uncategorized:"))
  }

  @Test
  func instructionsDoNotMentionMultipleCategories() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech")
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(!instructions.contains("Prefer fewer categories"))
    #expect(!instructions.contains("subcategories over parents"))
  }
}

// MARK: - Pure Helper Tests (stripHTMLToPlainText, formatEntryDate)

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

// MARK: - Story Key Normalization Tests (uses extracted normalizeStoryKey)

struct StoryKeyTests {
  @Test
  func producesKebabCase() {
    #expect(normalizeStoryKey("Apple M5 MacBook Pro!!") == "apple-m5-macbook-pro")
  }

  @Test
  func lowercasesInput() {
    #expect(normalizeStoryKey("UPPERCASE") == "uppercase")
  }

  @Test
  func replacesSpecialChars() {
    #expect(normalizeStoryKey("hello@world#2024") == "hello-world-2024")
  }

  @Test
  func trimsDashes() {
    #expect(normalizeStoryKey("--hello--") == "hello")
  }

  @Test
  func emptyInputReturnsDefault() {
    #expect(normalizeStoryKey("") == "story-unknown")
  }

  @Test
  func specialCharsOnlyReturnsDefault() {
    #expect(normalizeStoryKey("!!!@@@") == "story-unknown")
  }

  @Test
  func truncatesAt80Chars() {
    let longInput = String(repeating: "a", count: 100)
    let result = normalizeStoryKey(longInput)
    #expect(result.count == 80)
  }

  @Test
  func collapsesMultipleDashes() {
    #expect(normalizeStoryKey("hello   world") == "hello-world")
  }
}

// MARK: - Confidence Gate Tests

struct ConfidenceGateTests {
  @Test
  func highLLMConfidenceKeepsLabel() {
    let result = applyConfidenceGate(label: "apple", llmConfidence: 0.8, keywordScores: [:])
    #expect(result == "apple")
  }

  @Test
  func lowLLMButHighKeywordKeepsLabel() {
    let result = applyConfidenceGate(label: "apple", llmConfidence: 0.1, keywordScores: ["apple": 0.8])
    #expect(result == "apple")
  }

  @Test
  func bothLowDefaultsToUncategorized() {
    let result = applyConfidenceGate(label: "apple", llmConfidence: 0.1, keywordScores: ["apple": 0.2])
    #expect(result == uncategorizedLabel)
  }

  @Test
  func bothHighKeepsLabel() {
    let result = applyConfidenceGate(label: "apple", llmConfidence: 0.9, keywordScores: ["apple": 0.8])
    #expect(result == "apple")
  }

  @Test
  func atThresholdKeepsLabel() {
    let result = applyConfidenceGate(label: "gaming", llmConfidence: 0.3, keywordScores: [:])
    #expect(result == "gaming")
  }

  @Test
  func justBelowThresholdGates() {
    let result = applyConfidenceGate(label: "gaming", llmConfidence: 0.29, keywordScores: [:])
    #expect(result == uncategorizedLabel)
  }

  @Test
  func keywordScoreForDifferentCategoryIgnored() {
    let result = applyConfidenceGate(label: "gaming", llmConfidence: 0.1, keywordScores: ["apple": 0.9])
    #expect(result == uncategorizedLabel)
  }

  // Keyword override tests — when LLM chose uncategorized but keywords are strong
  @Test
  func keywordOverridesUncategorized() {
    let result = applyConfidenceGate(
      label: uncategorizedLabel, llmConfidence: 0.2, keywordScores: ["apple": 0.8])
    #expect(result == "apple")
  }

  @Test
  func keywordDoesNotOverrideIfBelowThreshold() {
    let result = applyConfidenceGate(
      label: uncategorizedLabel, llmConfidence: 0.2, keywordScores: ["apple": 0.6])
    #expect(result == uncategorizedLabel)
  }

  @Test
  func keywordOverridePicksHighestScore() {
    let result = applyConfidenceGate(
      label: uncategorizedLabel, llmConfidence: 0.1,
      keywordScores: ["apple": 0.8, "gaming": 1.0])
    #expect(result == "gaming")
  }
}

// MARK: - Keyword Match Confidence Tests

struct KeywordMatchConfidenceTests {
  private let categories: [CategoryDefinition] = [
    CategoryDefinition(
      label: "apple", description: "Apple", folderLabel: "technology",
      keywords: ["apple", "iphone", "macbook"]),
    CategoryDefinition(
      label: "gaming", description: "Gaming",
      keywords: ["xbox", "nintendo"]),
    CategoryDefinition(
      label: "world_news", description: "World"),
    CategoryDefinition(
      label: uncategorizedLabel, description: "Uncategorized"),
  ]

  @Test
  func titleMatchReturnsHighConfidence() {
    let result = keywordMatchConfidence(title: "Apple announces new iPhone", body: "", categories: categories)
    #expect(result["apple"]! >= 0.8)
  }

  @Test
  func bodyOnlyMatchReturnsLowerConfidence() {
    let result = keywordMatchConfidence(title: "Tech news today", body: "The new MacBook is here", categories: categories)
    #expect(result["apple"]! >= 0.4)
    #expect(result["apple"]! < 0.8)
  }

  @Test
  func noMatchReturnsEmpty() {
    let result = keywordMatchConfidence(title: "Weather forecast", body: "It will rain tomorrow", categories: categories)
    #expect(result.isEmpty)
  }

  @Test
  func multipleKeywordHitsIncrease() {
    let result = keywordMatchConfidence(title: "Apple iPhone and MacBook", body: "", categories: categories)
    #expect(result["apple"]! == 1.0)
  }

  @Test
  func caseInsensitive() {
    let result = keywordMatchConfidence(title: "APPLE IPHONE", body: "", categories: categories)
    #expect(result["apple"] != nil)
  }

  @Test
  func categoriesWithNoKeywordsSkipped() {
    let result = keywordMatchConfidence(title: "World leaders meet", body: "Global summit", categories: categories)
    #expect(result["world_news"] == nil)
  }

  @Test
  func cappedAtOne() {
    let result = keywordMatchConfidence(title: "Apple iPhone MacBook", body: "apple iphone macbook", categories: categories)
    #expect(result["apple"]! == 1.0)
  }
}

// MARK: - Input Validation Gate Tests

struct InputValidationGateTests {
  @Test
  func emptyTitleAndBodySkips() {
    #expect(shouldSkipClassification(title: "Untitled", body: "") == true)
  }

  @Test
  func emptyTitleAndWhitespaceBodySkips() {
    #expect(shouldSkipClassification(title: "Untitled", body: "   \n\t  ") == true)
  }

  @Test
  func realTitleWithEmptyBodyDoesNotSkip() {
    #expect(shouldSkipClassification(title: "Apple announces M5", body: "") == false)
  }

  @Test
  func untitledWithBodyDoesNotSkip() {
    #expect(shouldSkipClassification(title: "Untitled", body: "Some article content here") == false)
  }

  @Test
  func realTitleAndBodyDoesNotSkip() {
    #expect(shouldSkipClassification(title: "Breaking News", body: "Details about the event") == false)
  }
}

// MARK: - FeedbinClient Pure Helper Tests

struct FeedbinHelperTests {
  // MARK: - Link Header Parsing

  @Test
  func hasNextPageWithNextLink() {
    #expect(hasNextPageInLinkHeader("<https://api.feedbin.com/v2/entries.json?page=2>; rel=\"next\"") == true)
  }

  @Test
  func hasNextPageWithoutNextLink() {
    #expect(hasNextPageInLinkHeader("<https://api.feedbin.com/v2/entries.json?page=1>; rel=\"prev\"") == false)
  }

  @Test
  func hasNextPageNilHeader() {
    #expect(hasNextPageInLinkHeader(nil) == false)
  }

  @Test
  func hasNextPageEmptyString() {
    #expect(hasNextPageInLinkHeader("") == false)
  }

  // MARK: - Date Formatting for Feedbin API

  @Test
  func formatDateProducesISO8601() {
    let date = Date(timeIntervalSince1970: 0)
    let result = formatDateForFeedbin(date)
    #expect(result.contains("1970-01-01"))
    #expect(result.contains("T"))
  }

  @Test
  func formatDateIncludesFractionalSeconds() {
    let date = Date(timeIntervalSince1970: 1.5)
    let result = formatDateForFeedbin(date)
    #expect(result.contains("."))
  }

  // MARK: - HTTP Status Code Mapping

  @Test
  func successReturnsNil() {
    #expect(mapHTTPStatus(200) == nil)
    #expect(mapHTTPStatus(201) == nil)
    #expect(mapHTTPStatus(299) == nil)
  }

  @Test
  func unauthorizedMapped() {
    if case .unauthorized = mapHTTPStatus(401)! {
      // pass
    } else {
      Issue.record("Expected unauthorized")
    }
  }

  @Test
  func forbiddenMapped() {
    if case .forbidden = mapHTTPStatus(403)! {
      // pass
    } else {
      Issue.record("Expected forbidden")
    }
  }

  @Test
  func notFoundMapped() {
    if case .notFound = mapHTTPStatus(404)! {
      // pass
    } else {
      Issue.record("Expected notFound")
    }
  }

  @Test
  func rateLimitedMapped() {
    if case .rateLimited = mapHTTPStatus(429)! {
      // pass
    } else {
      Issue.record("Expected rateLimited")
    }
  }

  @Test
  func serverErrorMapped() {
    if case .httpError(let code) = mapHTTPStatus(500)! {
      #expect(code == 500)
    } else {
      Issue.record("Expected httpError")
    }
  }
}

// MARK: - ArticleBlock Tests

struct ArticleBlockTests {
  @Test
  func jsonRoundtrip() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Hello world"),
      .heading(level: 2, text: "Title"),
      .codeBlock(code: "let x = 1"),
      .blockquote(text: "A wise quote"),
      .divider,
    ]
    let data = blocks.toJSONData()
    #expect(data != nil)
    let decoded = [ArticleBlock].from(data!)
    #expect(decoded?.count == 5)
  }

  @Test
  func emptyBlocksRoundtrip() {
    let blocks: [ArticleBlock] = []
    let data = blocks.toJSONData()
    #expect(data != nil)
    let decoded = [ArticleBlock].from(data!)
    #expect(decoded?.isEmpty == true)
  }

  @Test
  func classificationTextParagraph() {
    let blocks: [ArticleBlock] = [.paragraph(text: "Hello world")]
    #expect(blocks.classificationText == "Hello world")
  }

  @Test
  func classificationTextSkipsImages() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Before"),
      .image(url: "https://example.com/img.png", alt: "An image"),
      .paragraph(text: "After"),
    ]
    let text = blocks.classificationText
    #expect(text.contains("Before"))
    #expect(text.contains("After"))
    #expect(!text.contains("img.png"))
  }

  @Test
  func classificationTextSkipsDividers() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Above"),
      .divider,
      .paragraph(text: "Below"),
    ]
    let text = blocks.classificationText
    #expect(text == "Above\nBelow")
  }

  @Test
  func classificationTextJoinsListItems() {
    let blocks: [ArticleBlock] = [
      .list(ordered: false, items: ["one", "two", "three"])
    ]
    let text = blocks.classificationText
    #expect(text.contains("one"))
    #expect(text.contains("two"))
    #expect(text.contains("three"))
  }
}

// MARK: - Entry Content Fallback Tests

@MainActor
struct EntryContentFallbackTests {
  private func makeEntry(
    content: String? = nil,
    summary: String? = nil,
    extractedContent: String? = nil
  ) -> Entry {
    let entry = Entry(
      feedbinEntryID: 1,
      title: "Test",
      author: nil,
      url: "https://example.com/article",
      content: content,
      summary: summary,
      extractedContentURL: nil,
      publishedAt: .now,
      createdAt: .now
    )
    if let extracted = extractedContent {
      entry.extractedContent = extracted
    }
    return entry
  }

  @Test
  func feedHTMLReturnsFeedContentIgnoringExtracted() {
    let entry = makeEntry(content: "<p>feed</p>", extractedContent: "<p>extracted</p>")
    #expect(entry.feedHTML == "<p>feed</p>")
  }

  @Test
  func feedHTMLReturnsSummaryAsFallback() {
    let entry = makeEntry(summary: "A summary")
    #expect(entry.feedHTML == "A summary")
  }

  @Test
  func feedHTMLReturnsFallbackWhenAllEmpty() {
    let entry = makeEntry()
    #expect(entry.feedHTML.contains("no inline content"))
    #expect(entry.feedHTML.contains("https://example.com/article"))
  }

  @Test
  func parsedBlocksReturnsFallbackWhenEmpty() {
    let entry = makeEntry()
    let blocks = entry.parsedBlocks
    #expect(blocks.count == 1)
    if case .paragraph(let text) = blocks.first {
      #expect(text.contains("no inline content"))
      #expect(text.contains("example.com/article"))
    } else {
      Issue.record("Expected paragraph block")
    }
  }
}

// MARK: - Video Iframe Transform Tests

struct VideoIframeTransformTests {
  @Test
  func replacesYouTubeIframe() {
    let html = """
      <iframe src="https://www.youtube.com/embed/abc123?rel=0" width="1280" height="720"></iframe>
      <p>Description</p>
      """
    let result = replaceVideoIframes(html)
    #expect(result.contains("i.ytimg.com/vi/abc123/hqdefault.jpg"))
    #expect(result.contains("youtube.com/watch?v=abc123"))
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("<iframe"))
  }

  @Test
  func leavesNonVideoIframeUnchanged() {
    let html = #"<iframe src="https://example.com/widget"></iframe>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("<iframe"))
  }

  @Test
  func returnsUnchangedWithoutIframes() {
    let html = "<p>Just text</p>"
    let result = replaceVideoIframes(html)
    #expect(result == html)
  }

  @Test
  func extractsYouTubeVideoID() {
    #expect(extractYouTubeVideoID(from: "https://www.youtube.com/embed/abc123") == "abc123")
    #expect(extractYouTubeVideoID(from: "https://youtube.com/embed/xyz?rel=0") == "xyz")
    #expect(extractYouTubeVideoID(from: "https://www.youtube-nocookie.com/embed/priv1") == "priv1")
    #expect(extractYouTubeVideoID(from: "https://vimeo.com/123") == nil)
    #expect(extractYouTubeVideoID(from: "https://www.youtube.com/watch?v=abc") == nil)
  }

  @Test
  func handlesIframeWithFallbackContent() {
    let html =
      #"<iframe src="https://www.youtube.com/embed/fb1">Your browser does not support iframes.</iframe>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("does not support"))
    #expect(!result.contains("</iframe>"))
  }

  @Test
  func matchesSelfClosingIframe() {
    let html = #"<iframe src="https://www.youtube.com/embed/sc1" />"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("<iframe"))
  }

  @Test
  func transformThenParseProducesBlocks() {
    let html = """
      <iframe src="https://www.youtube.com/embed/test123" width="640" height="360"></iframe>
      <p>Video description</p>
      """
    let transformed = replaceVideoIframes(html)
    let blocks = parseHTMLToBlocks(transformed)
    // The transformed HTML contains <a><img>...</a> which parses as inline markdown with image
    #expect(!blocks.isEmpty)
    let allText = blocks.compactMap { block -> String? in
      guard case .paragraph(let text) = block else { return nil }
      return text
    }.joined()
    #expect(allText.contains("ytimg.com"))
  }
}
