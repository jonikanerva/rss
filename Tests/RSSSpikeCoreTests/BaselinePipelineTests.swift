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
        XCTAssertEqual(output.items[0].categories, ["unsorted"])
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
}

private struct StubCategorizer: EntryCategorizer {
    let result: CategoryPrediction?

    func predict(for entry: FeedEntry) -> [CategoryPrediction] {
        if let result { return [result] } else { return [] }
    }
}
