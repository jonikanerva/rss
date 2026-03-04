import XCTest
@testable import RSSSpikeCore

final class BaselinePipelineTests: XCTestCase {
    func testProcessAssignsFallbackCategoryWhenConfidenceBelowThreshold() {
        let entry = FeedEntry(
            id: "1",
            sourceID: "feed-a",
            title: "Apple ships new chip",
            summary: "Performance and efficiency gains",
            publishedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 2_100)
        )

        let pipeline = BaselinePipeline(
            categorizer: StubCategorizer(result: CategoryPrediction(label: "tech", confidence: 0.4)),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let output = pipeline.process(entries: [entry])

        XCTAssertEqual(output.items.count, 1)
        XCTAssertEqual(output.items[0].category, "unsorted")
        XCTAssertEqual(output.items[0].categorySource, .fallback)
    }

    func testProcessCreatesSameGroupForEquivalentHeadlinesAcrossSources() {
        let first = FeedEntry(
            id: "1",
            sourceID: "feed-a",
            title: "OpenAI releases GPT update",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 2_100)
        )

        let second = FeedEntry(
            id: "2",
            sourceID: "feed-b",
            title: "  openai releases gpt update  ",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_900),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 2_050)
        )

        let pipeline = BaselinePipeline(
            categorizer: StubCategorizer(result: CategoryPrediction(label: "ai", confidence: 0.9)),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let output = pipeline.process(entries: [first, second])

        XCTAssertEqual(output.items.count, 2)
        XCTAssertEqual(output.items[0].groupID, output.items[1].groupID)
    }

    func testProcessReturnsNewestFirstOrderByCanonicalTimestamp() {
        let older = FeedEntry(
            id: "old",
            sourceID: "feed-a",
            title: "Older",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_100)
        )

        let newer = FeedEntry(
            id: "new",
            sourceID: "feed-a",
            title: "Newer",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 2_100)
        )

        let pipeline = BaselinePipeline(
            categorizer: StubCategorizer(result: CategoryPrediction(label: "general", confidence: 1.0)),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let output = pipeline.process(entries: [older, newer])

        XCTAssertEqual(output.items.map(\.id), ["new", "old"])
        XCTAssertEqual(output.chronologyReport.inversionRate, 0)
    }

    func testProcessPropagatesHierarchyForMultiLabelPrediction() {
        let entry = FeedEntry(
            id: "ps5-1",
            sourceID: "feed-games",
            title: "PlayStation 5 gets a major update",
            summary: "Sony details improvements",
            publishedAt: Date(timeIntervalSince1970: 3_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 3_100)
        )

        let hierarchy = TaxonomyHierarchy(
            ancestorsByCategory: [
                "playstation 5": ["technology", "video games"],
            ]
        )

        let pipeline = BaselinePipeline(
            categorizer: StubMultiLabelCategorizer(
                prediction: CategoryPrediction(
                    scores: [
                        CategoryScore(label: "playstation 5", confidence: 0.95),
                    ]
                )
            ),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6,
            hierarchy: hierarchy
        )

        let output = pipeline.process(entries: [entry])

        XCTAssertEqual(output.items.count, 1)
        XCTAssertEqual(output.items[0].categories, ["technology", "video games", "playstation 5"])
        XCTAssertEqual(output.items[0].category, "technology")
        XCTAssertEqual(output.items[0].categorySource, .model)
    }

    func testProcessUsesModelStoryKeyForGroupingAcrossDifferentTitles() {
        let first = FeedEntry(
            id: "1",
            sourceID: "feed-a",
            title: "Sony reveals PS5 update details",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 4_000),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 4_100)
        )

        let second = FeedEntry(
            id: "2",
            sourceID: "feed-b",
            title: "PlayStation 5 patch notes now live",
            summary: "",
            publishedAt: Date(timeIntervalSince1970: 4_050),
            updatedAt: nil,
            fetchedAt: Date(timeIntervalSince1970: 4_120)
        )

        let pipeline = BaselinePipeline(
            categorizer: StoryKeyCategorizer(),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let output = pipeline.process(entries: [first, second])
        XCTAssertEqual(output.items.count, 2)
        XCTAssertEqual(output.items[0].groupID, output.items[1].groupID)
    }
}

private struct StubCategorizer: EntryCategorizer {
    let result: CategoryPrediction?

    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        result
    }
}

private struct StubMultiLabelCategorizer: EntryCategorizer {
    let prediction: CategoryPrediction?

    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        prediction
    }
}

private struct StoryKeyCategorizer: EntryCategorizer {
    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        CategoryPrediction(
            scores: [CategoryScore(label: "playstation 5", confidence: 0.95)],
            storyKey: "sony-ps5-update"
        )
    }
}
