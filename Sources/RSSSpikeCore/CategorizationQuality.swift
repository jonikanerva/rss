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
    /// Evaluate multi-label categorization quality.
    /// `predictedCategoriesByItemID` maps item ID to all predicted categories.
    public static func evaluate(
        truthLabels: [TaxonomyLabel],
        predictedCategoriesByItemID: [String: [String]]
    ) -> CategorizationQualityMetrics {
        // Build truth: itemID -> Set<category>
        var truthByItemID: [String: Set<String>] = [:]
        for label in truthLabels {
            truthByItemID[label.itemID, default: []].insert(label.category)
        }

        let allCategories = Set(truthLabels.map(\.category))
        var perCategory: [String: Double] = [:]
        perCategory.reserveCapacity(allCategories.count)

        // Count evaluated items (items that appear in both truth and prediction)
        let evaluatedItemIDs = Set(truthByItemID.keys).intersection(Set(predictedCategoriesByItemID.keys))
        let evaluatedItemCount = evaluatedItemIDs.count

        for category in allCategories {
            var tp = 0
            var fp = 0
            var fn = 0

            for itemID in evaluatedItemIDs {
                let truthSet = truthByItemID[itemID] ?? []
                let predSet = Set(predictedCategoriesByItemID[itemID] ?? [])

                let inTruth = truthSet.contains(category)
                let inPred = predSet.contains(category)

                if inPred && inTruth {
                    tp += 1
                } else if inPred && !inTruth {
                    fp += 1
                } else if !inPred && inTruth {
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
