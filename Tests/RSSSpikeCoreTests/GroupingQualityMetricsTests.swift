import XCTest
@testable import RSSSpikeCore

final class GroupingQualityMetricsTests: XCTestCase {
    func testEvaluateComputesPuritySplitAndOvermergeRates() {
        let labels: [StoryPairLabel] = [
            StoryPairLabel(itemIDA: "1", itemIDB: "2", label: .sameStory),
            StoryPairLabel(itemIDA: "1", itemIDB: "3", label: .differentStory),
            StoryPairLabel(itemIDA: "3", itemIDB: "4", label: .differentStory),
        ]

        let groupByItemID: [String: String] = [
            "1": "g-a",
            "2": "g-b",
            "3": "g-a",
            "4": "g-c",
        ]

        let metrics = GroupingQualityEvaluator.evaluate(labels: labels, predictedGroupByItemID: groupByItemID)

        XCTAssertEqual(metrics.sameStoryPairCount, 1)
        XCTAssertEqual(metrics.differentStoryPairCount, 2)
        XCTAssertEqual(metrics.splitRate, 1.0)
        XCTAssertEqual(metrics.overmergeRate, 0.5)
        XCTAssertEqual(metrics.groupPurity, 0)
    }
}
