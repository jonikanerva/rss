import Foundation

public struct TaxonomyLabel: Equatable, Sendable {
    public let itemID: String
    public let category: String

    public init(itemID: String, category: String) {
        self.itemID = itemID
        self.category = category
    }
}

public struct CategorizationQualityMetrics: Equatable, Sendable {
    public let evaluatedItemCount: Int
    public let macroF1: Double
    public let perCategoryF1: [String: Double]

    public init(evaluatedItemCount: Int, macroF1: Double, perCategoryF1: [String: Double]) {
        self.evaluatedItemCount = evaluatedItemCount
        self.macroF1 = macroF1
        self.perCategoryF1 = perCategoryF1
    }
}

public enum CategorizationQualityEvaluator {
    public static func evaluate(
        truthLabels: [TaxonomyLabel],
        predictedCategoryByItemID: [String: String]
    ) -> CategorizationQualityMetrics {
        var labelByItemID: [String: String] = [:]
        for label in truthLabels {
            labelByItemID[label.itemID] = label.category
        }

        let categories = Set(truthLabels.map(\.category))
        var perCategory: [String: Double] = [:]
        perCategory.reserveCapacity(categories.count)

        var evaluatedItemCount = 0
        for label in truthLabels {
            if predictedCategoryByItemID[label.itemID] != nil {
                evaluatedItemCount += 1
            }
        }

        for category in categories {
            var tp = 0
            var fp = 0
            var fn = 0

            for (itemID, predicted) in predictedCategoryByItemID {
                guard let truth = labelByItemID[itemID] else {
                    continue
                }

                if predicted == category && truth == category {
                    tp += 1
                } else if predicted == category && truth != category {
                    fp += 1
                } else if predicted != category && truth == category {
                    fn += 1
                }
            }

            let precision = ratio(tp, tp + fp)
            let recall = ratio(tp, tp + fn)
            let f1 = (precision + recall) > 0 ? (2 * precision * recall) / (precision + recall) : 0
            perCategory[category] = f1
        }

        let macroF1 = perCategory.isEmpty ? 0 : perCategory.values.reduce(0, +) / Double(perCategory.count)
        return CategorizationQualityMetrics(
            evaluatedItemCount: evaluatedItemCount,
            macroF1: macroF1,
            perCategoryF1: perCategory
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }
}
