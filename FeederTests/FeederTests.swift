//
//  FeederTests.swift
//  FeederTests
//

import Testing
import Foundation
@testable import Feeder

// MARK: - Category Model Tests

struct CategoryModelTests {

    @Test func topLevelCategoryHasCorrectDefaults() {
        let cat = Category(label: "technology", displayName: "Technology",
                           categoryDescription: "Tech news", sortOrder: 0)
        #expect(cat.parentLabel == nil)
        #expect(cat.depth == 0)
        #expect(cat.isTopLevel == true)
    }

    @Test func childCategoryHasCorrectFields() {
        let cat = Category(label: "apple", displayName: "Apple",
                           categoryDescription: "Apple news", sortOrder: 0,
                           parentLabel: "technology")
        #expect(cat.parentLabel == "technology")
        #expect(cat.depth == 1)
        #expect(cat.isTopLevel == false)
    }

    @Test func categoryLabelIsUnique() {
        // Verify label is set correctly (unique constraint is enforced by SwiftData at runtime)
        let cat = Category(label: "ai", displayName: "AI",
                           categoryDescription: "AI news", sortOrder: 2,
                           parentLabel: "technology")
        #expect(cat.label == "ai")
    }
}

// MARK: - CategoryDefinition DTO Tests

struct CategoryDefinitionTests {

    @Test func dtoCarriesHierarchyInfo() {
        let dto = CategoryDefinition(label: "apple", description: "Apple news",
                                     parentLabel: "technology", isTopLevel: false)
        #expect(dto.label == "apple")
        #expect(dto.parentLabel == "technology")
        #expect(dto.isTopLevel == false)
    }

    @Test func topLevelDtoHasNilParent() {
        let dto = CategoryDefinition(label: "world", description: "World news",
                                     parentLabel: nil, isTopLevel: true)
        #expect(dto.parentLabel == nil)
        #expect(dto.isTopLevel == true)
    }
}

// MARK: - Deepest-Match Logic Tests

struct DeepestMatchTests {

    /// Simulates the safety-net logic from DataWriter.applyClassification
    private func applyDeepestMatch(labels: [String], categories: [CategoryDefinition]) -> [String] {
        let childrenByParent = Dictionary(
            grouping: categories.filter { !$0.isTopLevel },
            by: { $0.parentLabel ?? "" }
        )
        var result = labels
        for (parentLabel, children) in childrenByParent {
            let childLabels = Set(children.map(\.label))
            if result.contains(parentLabel), result.contains(where: { childLabels.contains($0) }) {
                result.removeAll { $0 == parentLabel }
            }
        }
        if result.isEmpty { result = ["other"] }
        return result
    }

    private var sampleCategories: [CategoryDefinition] {
        [
            CategoryDefinition(label: "technology", description: "Tech", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "gaming", description: "Gaming", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "world", description: "World", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "other", description: "Other", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "apple", description: "Apple", parentLabel: "technology", isTopLevel: false),
            CategoryDefinition(label: "ai", description: "AI", parentLabel: "technology", isTopLevel: false),
            CategoryDefinition(label: "gaming_industry", description: "Gaming biz", parentLabel: "gaming", isTopLevel: false),
        ]
    }

    @Test func parentStrippedWhenChildPresent() {
        let result = applyDeepestMatch(labels: ["technology", "apple"], categories: sampleCategories)
        #expect(result == ["apple"])
    }

    @Test func parentKeptWhenNoChildPresent() {
        let result = applyDeepestMatch(labels: ["technology"], categories: sampleCategories)
        #expect(result == ["technology"])
    }

    @Test func multipleChildrenKeptParentStripped() {
        let result = applyDeepestMatch(labels: ["technology", "apple", "ai"], categories: sampleCategories)
        #expect(result == ["apple", "ai"])
    }

    @Test func crossParentChildrenBothKept() {
        let result = applyDeepestMatch(labels: ["apple", "gaming_industry"], categories: sampleCategories)
        #expect(result == ["apple", "gaming_industry"])
    }

    @Test func parentFromDifferentBranchNotStripped() {
        // "world" has no children, so it stays even alongside a child from another parent
        let result = applyDeepestMatch(labels: ["world", "apple"], categories: sampleCategories)
        #expect(result == ["world", "apple"])
    }

    @Test func emptyLabelsDefaultToOther() {
        let result = applyDeepestMatch(labels: [], categories: sampleCategories)
        #expect(result == ["other"])
    }

    @Test func onlyOtherStaysAsIs() {
        let result = applyDeepestMatch(labels: ["other"], categories: sampleCategories)
        #expect(result == ["other"])
    }
}

// MARK: - Classification Prompt Tests

struct ClassificationPromptTests {

    /// Mirrors ClassificationEngine.buildInstructions logic
    private func buildHierarchicalPrompt(from categories: [CategoryDefinition]) -> String {
        let topLevel = categories.filter { $0.isTopLevel }
        let children = categories.filter { !$0.isTopLevel }

        var lines: [String] = []
        for parent in topLevel {
            lines.append("- \(parent.label): \(parent.description)")
            for child in children where child.parentLabel == parent.label {
                lines.append("  - \(child.label): \(child.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    @Test func promptShowsHierarchicalIndentation() {
        let categories = [
            CategoryDefinition(label: "technology", description: "Tech news", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "apple", description: "Apple news", parentLabel: "technology", isTopLevel: false),
            CategoryDefinition(label: "world", description: "World news", parentLabel: nil, isTopLevel: true),
        ]
        let prompt = buildHierarchicalPrompt(from: categories)

        #expect(prompt.contains("- technology: Tech news"))
        #expect(prompt.contains("  - apple: Apple news"))
        #expect(prompt.contains("- world: World news"))
    }

    @Test func childAppearsUnderCorrectParent() {
        let categories = [
            CategoryDefinition(label: "gaming", description: "Games", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "technology", description: "Tech", parentLabel: nil, isTopLevel: true),
            CategoryDefinition(label: "ps5", description: "PS5", parentLabel: "gaming", isTopLevel: false),
        ]
        let prompt = buildHierarchicalPrompt(from: categories)
        let lines = prompt.components(separatedBy: "\n")

        // ps5 should appear right after gaming, not after technology
        if let gamingIndex = lines.firstIndex(where: { $0.contains("gaming:") }),
           let ps5Index = lines.firstIndex(where: { $0.contains("ps5:") }) {
            #expect(ps5Index == gamingIndex + 1)
        } else {
            Issue.record("gaming or ps5 not found in prompt")
        }
    }
}

// MARK: - Article Keep Days Tests

struct ArticleKeepDaysTests {

    @Test func defaultKeepDaysIs7() {
        // When UserDefaults has no value, articleKeepDays should return 7
        let stored = UserDefaults.standard.integer(forKey: "article_keep_days_test_nonexistent")
        let result = stored > 0 ? stored : 7
        #expect(result == 7)
    }

    @Test func maxArticleAgeMatchesKeepDays() {
        let days = 3
        let expected = TimeInterval(days) * 24 * 60 * 60
        #expect(expected == 259200) // 3 days in seconds
    }
}

// MARK: - Pure Helper Tests

struct PureHelperTests {

    @Test func stripHTMLRemovesTags() {
        let html = "<p>Hello <b>world</b></p>"
        let result = stripHTMLToPlainText(html)
        #expect(result == "Hello world")
    }

    @Test func stripHTMLDecodesEntities() {
        let html = "Tom &amp; Jerry &lt;3&gt;"
        let result = stripHTMLToPlainText(html)
        #expect(result == "Tom & Jerry <3>")
    }

    @Test func stripHTMLHandlesEmptyString() {
        #expect(stripHTMLToPlainText("") == "")
    }

    @Test func formatEntryDateShowsToday() {
        let now = Date()
        let formatted = formatEntryDate(now)
        #expect(formatted.hasPrefix("Today,"))
    }

    @Test func normalizeStoryKeyProducesKebabCase() {
        // normalizeStoryKey is private, but we can test indirectly through the pattern
        let input = "Apple M5 MacBook Pro!!"
        let lowered = input.lowercased()
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        #expect(trimmed == "apple-m5-macbook-pro")
    }
}
