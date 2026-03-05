import Foundation

public struct HierarchyQualityMetrics: Equatable, Sendable {
    public let evaluatedItemCount: Int
    public let constrainedItemCount: Int
    public let ancestorConsistencyRate: Double
    public let wrongPropagatedCategoryRate: Double
    public let hierarchyDepthCoverage: Double

    public init(
        evaluatedItemCount: Int,
        constrainedItemCount: Int,
        ancestorConsistencyRate: Double,
        wrongPropagatedCategoryRate: Double,
        hierarchyDepthCoverage: Double
    ) {
        self.evaluatedItemCount = evaluatedItemCount
        self.constrainedItemCount = constrainedItemCount
        self.ancestorConsistencyRate = ancestorConsistencyRate
        self.wrongPropagatedCategoryRate = wrongPropagatedCategoryRate
        self.hierarchyDepthCoverage = hierarchyDepthCoverage
    }
}

public enum HierarchyQualityEvaluator {
    public static func evaluate(
        predictedCategoriesByItemID: [String: [String]],
        hierarchy: TaxonomyHierarchy,
        knownCategories: Set<String>
    ) -> HierarchyQualityMetrics {
        let evaluatedItemCount = predictedCategoriesByItemID.count
        guard evaluatedItemCount > 0 else {
            return HierarchyQualityMetrics(
                evaluatedItemCount: 0,
                constrainedItemCount: 0,
                ancestorConsistencyRate: 1,
                wrongPropagatedCategoryRate: 0,
                hierarchyDepthCoverage: 1
            )
        }

        var requiredAncestorCount = 0
        var missingAncestorCount = 0
        var constrainedItemCount = 0
        var validDepthItemCount = 0

        for categories in predictedCategoriesByItemID.values {
            let categorySet = Set(categories)
            var itemRequiredAncestorCount = 0
            var itemMissingAncestorCount = 0

            for category in categorySet {
                if knownCategories.isEmpty == false, knownCategories.contains(category) == false {
                    continue
                }

                let requiredAncestors = hierarchy.ancestorsByCategory[category] ?? []
                if requiredAncestors.isEmpty {
                    continue
                }

                itemRequiredAncestorCount += requiredAncestors.count
                for ancestor in requiredAncestors where categorySet.contains(ancestor) == false {
                    itemMissingAncestorCount += 1
                }
            }

            if itemRequiredAncestorCount > 0 {
                constrainedItemCount += 1
                if itemMissingAncestorCount == 0 {
                    validDepthItemCount += 1
                }
            }

            requiredAncestorCount += itemRequiredAncestorCount
            missingAncestorCount += itemMissingAncestorCount
        }

        let ancestorConsistencyRate = requiredAncestorCount > 0
            ? ratio(requiredAncestorCount - missingAncestorCount, requiredAncestorCount)
            : 1
        let wrongPropagatedCategoryRate = requiredAncestorCount > 0
            ? ratio(missingAncestorCount, requiredAncestorCount)
            : 0
        let hierarchyDepthCoverage = constrainedItemCount > 0
            ? ratio(validDepthItemCount, constrainedItemCount)
            : 1

        return HierarchyQualityMetrics(
            evaluatedItemCount: evaluatedItemCount,
            constrainedItemCount: constrainedItemCount,
            ancestorConsistencyRate: clamped01(ancestorConsistencyRate),
            wrongPropagatedCategoryRate: clamped01(wrongPropagatedCategoryRate),
            hierarchyDepthCoverage: clamped01(hierarchyDepthCoverage)
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }

    private static func clamped01(_ value: Double) -> Double {
        if value < 0 {
            return 0
        }
        if value > 1 {
            return 1
        }

        return value
    }
}
