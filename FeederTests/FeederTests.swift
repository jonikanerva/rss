//
//  FeederTests.swift
//  FeederTests
//

import Foundation
import Testing

@testable import Feeder

// MARK: - Deepest-Match Logic Tests (uses extracted enforceDeepestMatch function)

struct DeepestMatchTests {
  private var sampleCategories: [CategoryDefinition] {
    [
      CategoryDefinition(label: "technology", description: "Tech", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "gaming", description: "Gaming", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "world", description: "World", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: uncategorizedLabel, description: "Uncategorized", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "apple", description: "Apple", parentLabel: "technology", isTopLevel: false),
      CategoryDefinition(label: "ai", description: "AI", parentLabel: "technology", isTopLevel: false),
      CategoryDefinition(label: "gaming_industry", description: "Gaming biz", parentLabel: "gaming", isTopLevel: false),
    ]
  }

  private var childrenByParent: [String: [CategoryDefinition]] {
    Dictionary(
      grouping: sampleCategories.filter { !$0.isTopLevel },
      by: { $0.parentLabel ?? "" }
    )
  }

  @Test
  func parentStrippedWhenChildPresent() {
    let result = enforceDeepestMatch(labels: ["technology", "apple"], childrenByParent: childrenByParent)
    #expect(result == ["apple"])
  }

  @Test
  func parentKeptWhenNoChildPresent() {
    let result = enforceDeepestMatch(labels: ["technology"], childrenByParent: childrenByParent)
    #expect(result == ["technology"])
  }

  @Test
  func multipleChildrenKeptParentStripped() {
    let result = enforceDeepestMatch(labels: ["technology", "apple", "ai"], childrenByParent: childrenByParent)
    #expect(result == ["apple", "ai"])
  }

  @Test
  func crossParentChildrenBothKept() {
    let result = enforceDeepestMatch(labels: ["apple", "gaming_industry"], childrenByParent: childrenByParent)
    #expect(result == ["apple", "gaming_industry"])
  }

  @Test
  func parentFromDifferentBranchNotStripped() {
    let result = enforceDeepestMatch(labels: ["world", "apple"], childrenByParent: childrenByParent)
    #expect(result == ["world", "apple"])
  }

  @Test
  func emptyLabelsDefaultToUncategorized() {
    let result = enforceDeepestMatch(labels: [], childrenByParent: childrenByParent)
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func onlyUncategorizedStaysAsIs() {
    let result = enforceDeepestMatch(labels: [uncategorizedLabel], childrenByParent: childrenByParent)
    #expect(result == [uncategorizedLabel])
  }
}

// MARK: - Classification Instructions Tests (uses extracted buildClassificationInstructions)

struct ClassificationInstructionsTests {
  @Test
  func promptShowsHierarchicalIndentation() {
    let categories = [
      CategoryDefinition(label: "technology", description: "Tech news", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "apple", description: "Apple news", parentLabel: "technology", isTopLevel: false),
      CategoryDefinition(label: "world", description: "World news", parentLabel: nil, isTopLevel: true),
    ]
    let instructions = buildClassificationInstructions(from: categories)

    #expect(instructions.contains("- technology: Tech news"))
    #expect(instructions.contains("  - apple: Apple news"))
    #expect(instructions.contains("- world: World news"))
  }

  @Test
  func childAppearsUnderCorrectParent() {
    let categories = [
      CategoryDefinition(label: "gaming", description: "Games", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "technology", description: "Tech", parentLabel: nil, isTopLevel: true),
      CategoryDefinition(label: "ps5", description: "PS5", parentLabel: "gaming", isTopLevel: false),
    ]
    let instructions = buildClassificationInstructions(from: categories)
    let lines = instructions.components(separatedBy: "\n")

    if let gamingIndex = lines.firstIndex(where: { $0.contains("gaming:") }),
      let ps5Index = lines.firstIndex(where: { $0.contains("ps5:") })
    {
      #expect(ps5Index == gamingIndex + 1)
    } else {
      Issue.record("gaming or ps5 not found in instructions")
    }
  }

  @Test
  func emptyCategories() {
    let instructions = buildClassificationInstructions(from: [])
    #expect(instructions.contains("Categories:"))
  }

  @Test
  func instructionsContainSystemDirective() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech", parentLabel: nil, isTopLevel: true)
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(instructions.contains("Categorize the article into the most specific matching categories"))
  }

  @Test
  func instructionsIncludeUncategorized() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech", parentLabel: nil, isTopLevel: true)
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(instructions.contains("- uncategorized:"))
  }

  @Test
  func instructionsDoNotOverpushUncategorized() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech", parentLabel: nil, isTopLevel: true)
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(!instructions.contains("assign only \"uncategorized\""))
  }

  @Test
  func instructionsPreferFewerCategories() {
    let categories = [
      CategoryDefinition(label: "tech", description: "Tech", parentLabel: nil, isTopLevel: true)
    ]
    let instructions = buildClassificationInstructions(from: categories)
    #expect(instructions.contains("Prefer fewer categories"))
  }
}

// MARK: - Filter Valid Labels Tests (uses extracted filterValidLabels)

struct FilterValidLabelsTests {
  private let validSet: Set<String> = ["technology", "apple", "gaming", "world", uncategorizedLabel]

  @Test
  func allValidLabelsKept() {
    let result = filterValidLabels(["technology", "apple"], validSet: validSet)
    #expect(result == ["technology", "apple"])
  }

  @Test
  func invalidLabelsRemoved() {
    let result = filterValidLabels(["technology", "nonexistent"], validSet: validSet)
    #expect(result == ["technology"])
  }

  @Test
  func allInvalidDefaultsToUncategorized() {
    let result = filterValidLabels(["bogus", "fake"], validSet: validSet)
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func emptyLabelsDefaultToUncategorized() {
    let result = filterValidLabels([], validSet: validSet)
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func singleValidLabel() {
    let result = filterValidLabels(["gaming"], validSet: validSet)
    #expect(result == ["gaming"])
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
  func highLLMConfidenceKeepsLabels() {
    let result = applyConfidenceGate(labels: ["apple"], llmConfidence: 0.8, keywordScores: [:])
    #expect(result == ["apple"])
  }

  @Test
  func lowLLMButHighKeywordKeepsLabels() {
    let result = applyConfidenceGate(labels: ["apple"], llmConfidence: 0.1, keywordScores: ["apple": 0.8])
    #expect(result == ["apple"])
  }

  @Test
  func bothLowDefaultsToUncategorized() {
    let result = applyConfidenceGate(labels: ["apple"], llmConfidence: 0.1, keywordScores: ["apple": 0.2])
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func bothHighKeepsLabels() {
    let result = applyConfidenceGate(labels: ["apple"], llmConfidence: 0.9, keywordScores: ["apple": 0.8])
    #expect(result == ["apple"])
  }

  @Test
  func atThresholdKeepsLabels() {
    let result = applyConfidenceGate(labels: ["gaming"], llmConfidence: 0.3, keywordScores: [:])
    #expect(result == ["gaming"])
  }

  @Test
  func justBelowThresholdGates() {
    let result = applyConfidenceGate(labels: ["gaming"], llmConfidence: 0.29, keywordScores: [:])
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func keywordScoreForDifferentCategoryIgnored() {
    let result = applyConfidenceGate(labels: ["gaming"], llmConfidence: 0.1, keywordScores: ["apple": 0.9])
    #expect(result == [uncategorizedLabel])
  }

  // Keyword override tests — when LLM chose uncategorized but keywords are strong
  @Test
  func keywordOverridesUncategorized() {
    let result = applyConfidenceGate(
      labels: [uncategorizedLabel], llmConfidence: 0.2, keywordScores: ["apple": 0.8])
    #expect(result == ["apple"])
  }

  @Test
  func keywordDoesNotOverrideIfBelowThreshold() {
    let result = applyConfidenceGate(
      labels: [uncategorizedLabel], llmConfidence: 0.2, keywordScores: ["apple": 0.6])
    #expect(result == [uncategorizedLabel])
  }

  @Test
  func keywordOverridePicksHighestScore() {
    let result = applyConfidenceGate(
      labels: [uncategorizedLabel], llmConfidence: 0.1,
      keywordScores: ["apple": 0.8, "gaming": 1.0])
    #expect(result == ["gaming"])
  }
}

// MARK: - Keyword Match Confidence Tests

struct KeywordMatchConfidenceTests {
  private let categories: [CategoryDefinition] = [
    CategoryDefinition(
      label: "apple", description: "Apple", parentLabel: "technology",
      isTopLevel: false, keywords: ["apple", "iphone", "macbook"]),
    CategoryDefinition(
      label: "gaming", description: "Gaming", parentLabel: nil,
      isTopLevel: true, keywords: ["xbox", "nintendo"]),
    CategoryDefinition(
      label: "world_news", description: "World", parentLabel: nil,
      isTopLevel: true, keywords: []),
    CategoryDefinition(
      label: uncategorizedLabel, description: "Uncategorized",
      parentLabel: nil, isTopLevel: true),
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
