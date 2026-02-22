import XCTest
@testable import RSSSpikeCore

final class CategorizationQualityMetricsTests: XCTestCase {
    func testEvaluateComputesMacroF1AndPerCategoryF1() {
        let truth = [
            TaxonomyLabel(itemID: "1", category: "ai"),
            TaxonomyLabel(itemID: "2", category: "ai"),
            TaxonomyLabel(itemID: "3", category: "apple"),
            TaxonomyLabel(itemID: "4", category: "security"),
        ]

        let predictedByItemID: [String: String] = [
            "1": "ai",
            "2": "apple",
            "3": "apple",
            "4": "security",
        ]

        let metrics = CategorizationQualityEvaluator.evaluate(
            truthLabels: truth,
            predictedCategoryByItemID: predictedByItemID
        )

        XCTAssertEqual(metrics.evaluatedItemCount, 4)
        XCTAssertEqual(metrics.perCategoryF1["ai"], 0.6666666666666666)
        XCTAssertEqual(metrics.perCategoryF1["apple"], 0.6666666666666666)
        XCTAssertEqual(metrics.perCategoryF1["security"], 1.0)
        XCTAssertEqual(metrics.macroF1, 0.7777777777777777)
    }
}
