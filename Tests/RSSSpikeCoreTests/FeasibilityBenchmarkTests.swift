import XCTest
@testable import RSSSpikeCore

final class FeasibilityBenchmarkTests: XCTestCase {
    func testRunComputesCompletionAndFallbackRates() {
        let entries = [
            FeedEntry(
                id: "1",
                sourceID: "feed-a",
                title: "AI launch",
                summary: "",
                publishedAt: Date(timeIntervalSince1970: 2_000),
                updatedAt: nil,
                fetchedAt: Date(timeIntervalSince1970: 2_100)
            ),
            FeedEntry(
                id: "2",
                sourceID: "feed-b",
                title: "No timestamp",
                summary: "",
                publishedAt: nil,
                updatedAt: nil,
                fetchedAt: nil
            ),
        ]

        let pipeline = BaselinePipeline(
            categorizer: StubBenchmarkCategorizer(predictions: ["1": CategoryPrediction(label: "tech", confidence: 0.2)]),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let labels = [StoryPairLabel(itemIDA: "1", itemIDB: "2", label: .sameStory)]
        let taxonomy = [TaxonomyLabel(itemID: "1", category: "unsorted")]
        let result = FeasibilityBenchmarkRunner.run(
            entries: entries,
            pipeline: pipeline,
            storyPairLabels: labels,
            taxonomyLabels: taxonomy
        )

        XCTAssertEqual(result.totalItemCount, 2)
        XCTAssertEqual(result.processedItemCount, 1)
        XCTAssertEqual(result.pipelineCompletionRate, 0.5)
        XCTAssertEqual(result.schemaValidRate, 0.5)
        XCTAssertEqual(result.fallbackRate, 1.0)
        XCTAssertEqual(result.groupingQuality.evaluatedPairCount, 0)
        XCTAssertEqual(result.categorizationQuality.evaluatedItemCount, 1)
        XCTAssertEqual(result.categorizationQuality.microF1, 1.0)
        XCTAssertEqual(result.categorizationQuality.macroF1, 1.0)
        XCTAssertEqual(result.categorizationQuality.jaccardScore, 1.0)
        XCTAssertEqual(result.hierarchyQuality.ancestorConsistencyRate, 1.0)
    }
}

private struct StubBenchmarkCategorizer: EntryCategorizer {
    let predictions: [String: CategoryPrediction]

    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        predictions[entry.id]
    }
}
