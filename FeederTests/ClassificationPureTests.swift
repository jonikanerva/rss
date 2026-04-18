import Foundation
import Testing

@testable import Feeder

// MARK: - buildClassificationInstructions

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

// MARK: - normalizeStoryKey

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

// MARK: - applyConfidenceGate

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

// MARK: - keywordMatchConfidence

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

// MARK: - shouldSkipClassification

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
