import Foundation

public struct FeasibilityBenchmarkResult: Equatable, Sendable {
    public let totalItemCount: Int
    public let processedItemCount: Int
    public let pipelineCompletionRate: Double
    public let schemaValidRate: Double
    public let fallbackRate: Double
    public let chronologyReport: ChronologyReport
    public let groupingQuality: GroupingQualityMetrics
    public let categorizationQuality: CategorizationQualityMetrics

    public init(
        totalItemCount: Int,
        processedItemCount: Int,
        pipelineCompletionRate: Double,
        schemaValidRate: Double,
        fallbackRate: Double,
        chronologyReport: ChronologyReport,
        groupingQuality: GroupingQualityMetrics,
        categorizationQuality: CategorizationQualityMetrics
    ) {
        self.totalItemCount = totalItemCount
        self.processedItemCount = processedItemCount
        self.pipelineCompletionRate = pipelineCompletionRate
        self.schemaValidRate = schemaValidRate
        self.fallbackRate = fallbackRate
        self.chronologyReport = chronologyReport
        self.groupingQuality = groupingQuality
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
            !$0.categories.isEmpty && $0.groupID.isEmpty == false
        }.count
        let schemaValidRate = safeRatio(numerator: schemaValidCount, denominator: totalItemCount)

        let fallbackCount = output.items.filter { $0.categorySource == .fallback }.count
        let fallbackRate = safeRatio(numerator: fallbackCount, denominator: max(1, processedItemCount))
        let predictedGroupByItemID = Dictionary(uniqueKeysWithValues: output.items.map { ($0.id, $0.groupID) })
        let groupingQuality = GroupingQualityEvaluator.evaluate(
            labels: storyPairLabels,
            predictedGroupByItemID: predictedGroupByItemID
        )
        let predictedCategoriesByItemID = Dictionary(uniqueKeysWithValues: output.items.map { ($0.id, $0.categories) })
        let categorizationQuality = CategorizationQualityEvaluator.evaluate(
            truthLabels: taxonomyLabels,
            predictedCategoriesByItemID: predictedCategoriesByItemID
        )

        return FeasibilityBenchmarkResult(
            totalItemCount: totalItemCount,
            processedItemCount: processedItemCount,
            pipelineCompletionRate: pipelineCompletionRate,
            schemaValidRate: schemaValidRate,
            fallbackRate: fallbackRate,
            chronologyReport: output.chronologyReport,
            groupingQuality: groupingQuality,
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
