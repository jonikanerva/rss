import Foundation

public struct FeasibilityBenchmarkResult: Equatable, Sendable {
    public let totalItemCount: Int
    public let processedItemCount: Int
    public let pipelineCompletionRate: Double
    public let schemaValidRate: Double
    public let fallbackRate: Double
    public let processedItems: [ProcessedItem]
    public let chronologyReport: ChronologyReport
    public let groupingQuality: GroupingQualityMetrics
    public let hierarchyQuality: HierarchyQualityMetrics
    public let categorizationQuality: CategorizationQualityMetrics

    public init(
        totalItemCount: Int,
        processedItemCount: Int,
        pipelineCompletionRate: Double,
        schemaValidRate: Double,
        fallbackRate: Double,
        processedItems: [ProcessedItem] = [],
        chronologyReport: ChronologyReport,
        groupingQuality: GroupingQualityMetrics,
        hierarchyQuality: HierarchyQualityMetrics,
        categorizationQuality: CategorizationQualityMetrics
    ) {
        self.totalItemCount = totalItemCount
        self.processedItemCount = processedItemCount
        self.pipelineCompletionRate = pipelineCompletionRate
        self.schemaValidRate = schemaValidRate
        self.fallbackRate = fallbackRate
        self.processedItems = processedItems
        self.chronologyReport = chronologyReport
        self.groupingQuality = groupingQuality
        self.hierarchyQuality = hierarchyQuality
        self.categorizationQuality = categorizationQuality
    }
}

public enum FeasibilityBenchmarkRunner {
    public static func run(
        entries: [FeedEntry],
        pipeline: BaselinePipeline,
        storyPairLabels: [StoryPairLabel] = [],
        taxonomyLabels: [TaxonomyLabel] = []
    ) -> FeasibilityBenchmarkResult {
        let output = pipeline.process(entries: entries)

        let totalItemCount = entries.count
        let processedItemCount = output.items.count
        let pipelineCompletionRate = safeRatio(numerator: processedItemCount, denominator: totalItemCount)

        let schemaValidCount = output.items.filter {
            $0.categories.isEmpty == false && $0.groupID.isEmpty == false
        }.count
        let schemaValidRate = safeRatio(numerator: schemaValidCount, denominator: totalItemCount)

        let fallbackCount = output.items.filter { $0.categorySource == .fallback }.count
        let fallbackRate = safeRatio(numerator: fallbackCount, denominator: max(1, processedItemCount))
        let predictedGroupByItemID = Dictionary(uniqueKeysWithValues: output.items.map { ($0.id, $0.groupID) })
        let predictedCategoriesByItemID = Dictionary(uniqueKeysWithValues: output.items.map { ($0.id, $0.categories) })
        let groupingQuality = GroupingQualityEvaluator.evaluate(
            labels: storyPairLabels,
            predictedGroupByItemID: predictedGroupByItemID,
            predictedCategoriesByItemID: predictedCategoriesByItemID
        )
        let categorizationQuality = CategorizationQualityEvaluator.evaluate(
            truthLabels: taxonomyLabels,
            predictedCategoriesByItemID: predictedCategoriesByItemID
        )
        let knownCategories = Set(taxonomyLabels.map { $0.category }).union(
            pipeline.hierarchy.ancestorsByCategory.values.flatMap { $0 }
        )
        let hierarchyQuality = HierarchyQualityEvaluator.evaluate(
            predictedCategoriesByItemID: predictedCategoriesByItemID,
            hierarchy: pipeline.hierarchy,
            knownCategories: knownCategories
        )

        return FeasibilityBenchmarkResult(
            totalItemCount: totalItemCount,
            processedItemCount: processedItemCount,
            pipelineCompletionRate: pipelineCompletionRate,
            schemaValidRate: schemaValidRate,
            fallbackRate: fallbackRate,
            processedItems: output.items,
            chronologyReport: output.chronologyReport,
            groupingQuality: groupingQuality,
            hierarchyQuality: hierarchyQuality,
            categorizationQuality: categorizationQuality
        )
    }

    private static func safeRatio(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }
}
