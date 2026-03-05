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
    public let microF1: Double
    public let macroF1: Double
    public let jaccardScore: Double
    public let perCategoryF1: [String: Double]

    public init(
        evaluatedItemCount: Int,
        microF1: Double,
        macroF1: Double,
        jaccardScore: Double,
        perCategoryF1: [String: Double]
    ) {
        self.evaluatedItemCount = evaluatedItemCount
        self.microF1 = microF1
        self.macroF1 = macroF1
        self.jaccardScore = jaccardScore
        self.perCategoryF1 = perCategoryF1
    }
}

public enum CategorizationQualityEvaluator {
    public static func evaluate(
        truthLabels: [TaxonomyLabel],
        predictedCategoriesByItemID: [String: [String]]
    ) -> CategorizationQualityMetrics {
        var truthLabelsByItemID: [String: Set<String>] = [:]
        for label in truthLabels {
            let normalizedCategory = label.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedCategory.isEmpty == false else {
                continue
            }

            truthLabelsByItemID[label.itemID, default: []].insert(normalizedCategory)
        }

        let normalizedPredicted = normalizePredictions(predictedCategoriesByItemID)
        let categories = Set(truthLabels.map(\.category)).union(normalizedPredicted.values.flatMap { $0 })
        var perCategory: [String: Double] = [:]
        perCategory.reserveCapacity(categories.count)

        let evaluatedItemIDs = truthLabelsByItemID.keys.filter { normalizedPredicted[$0] != nil }
        var microTP = 0
        var microFP = 0
        var microFN = 0
        var jaccardSum = 0.0

        for itemID in evaluatedItemIDs {
            let truthSet = truthLabelsByItemID[itemID] ?? []
            let predictedSet = normalizedPredicted[itemID] ?? []
            let intersectionCount = truthSet.intersection(predictedSet).count
            let falsePositiveCount = predictedSet.subtracting(truthSet).count
            let falseNegativeCount = truthSet.subtracting(predictedSet).count
            let unionCount = truthSet.union(predictedSet).count

            microTP += intersectionCount
            microFP += falsePositiveCount
            microFN += falseNegativeCount
            if unionCount > 0 {
                jaccardSum += Double(intersectionCount) / Double(unionCount)
            }
        }

        for category in categories {
            var tp = 0
            var fp = 0
            var fn = 0

            for itemID in evaluatedItemIDs {
                guard let truth = truthLabelsByItemID[itemID],
                      let predicted = normalizedPredicted[itemID]
                else {
                    continue
                }

                let truthHasCategory = truth.contains(category)
                let predictedHasCategory = predicted.contains(category)
                if predictedHasCategory && truthHasCategory {
                    tp += 1
                } else if predictedHasCategory && truthHasCategory == false {
                    fp += 1
                } else if predictedHasCategory == false && truthHasCategory {
                    fn += 1
                }
            }

            let precision = ratio(tp, tp + fp)
            let recall = ratio(tp, tp + fn)
            let f1 = (precision + recall) > 0 ? (2 * precision * recall) / (precision + recall) : 0
            perCategory[category] = f1
        }

        let evaluatedItemCount = evaluatedItemIDs.count
        let microF1 = ratio(2 * microTP, (2 * microTP) + microFP + microFN)
        let macroF1 = perCategory.isEmpty ? 0 : perCategory.values.reduce(0, +) / Double(perCategory.count)
        let jaccardScore = evaluatedItemCount > 0 ? jaccardSum / Double(evaluatedItemCount) : 0

        return CategorizationQualityMetrics(
            evaluatedItemCount: evaluatedItemCount,
            microF1: microF1,
            macroF1: macroF1,
            jaccardScore: jaccardScore,
            perCategoryF1: perCategory
        )
    }

    public static func evaluate(
        truthLabels: [TaxonomyLabel],
        predictedCategoryByItemID: [String: String]
    ) -> CategorizationQualityMetrics {
        let promoted = predictedCategoryByItemID.mapValues { [$0] }
        return evaluate(truthLabels: truthLabels, predictedCategoriesByItemID: promoted)
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }

    private static func normalizePredictions(_ predicted: [String: [String]]) -> [String: Set<String>] {
        var normalized: [String: Set<String>] = [:]
        normalized.reserveCapacity(predicted.count)

        for (itemID, categories) in predicted {
            let set = Set(
                categories
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
            )

            normalized[itemID] = set
        }

        return normalized
    }
}
