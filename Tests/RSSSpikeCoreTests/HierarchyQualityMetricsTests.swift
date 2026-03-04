import XCTest
@testable import RSSSpikeCore

final class HierarchyQualityMetricsTests: XCTestCase {
    func testEvaluateReportsPerfectConsistencyWhenAncestorsPresent() {
        let hierarchy = TaxonomyHierarchy(
            ancestorsByCategory: [
                "playstation 5": ["technology", "video games"],
            ]
        )

        let predicted: [String: [String]] = [
            "1": ["technology", "video games", "playstation 5"],
        ]

        let metrics = HierarchyQualityEvaluator.evaluate(
            predictedCategoriesByItemID: predicted,
            hierarchy: hierarchy,
            knownCategories: ["technology", "video games", "playstation 5"]
        )

        XCTAssertEqual(metrics.evaluatedItemCount, 1)
        XCTAssertEqual(metrics.constrainedItemCount, 1)
        XCTAssertEqual(metrics.ancestorConsistencyRate, 1)
        XCTAssertEqual(metrics.wrongPropagatedCategoryRate, 0)
        XCTAssertEqual(metrics.hierarchyDepthCoverage, 1)
    }

    func testEvaluateReportsMissingAncestorsAsPropagationErrors() {
        let hierarchy = TaxonomyHierarchy(
            ancestorsByCategory: [
                "playstation 5": ["technology", "video games"],
            ]
        )

        let predicted: [String: [String]] = [
            "1": ["playstation 5"],
        ]

        let metrics = HierarchyQualityEvaluator.evaluate(
            predictedCategoriesByItemID: predicted,
            hierarchy: hierarchy,
            knownCategories: ["technology", "video games", "playstation 5"]
        )

        XCTAssertEqual(metrics.ancestorConsistencyRate, 0)
        XCTAssertEqual(metrics.wrongPropagatedCategoryRate, 1)
        XCTAssertEqual(metrics.hierarchyDepthCoverage, 0)
    }
}
