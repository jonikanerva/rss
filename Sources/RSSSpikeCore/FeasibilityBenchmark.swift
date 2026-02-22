import Foundation

public struct FeasibilityBenchmarkResult: Equatable, Sendable {
    public let totalItemCount: Int
    public let processedItemCount: Int
    public let pipelineCompletionRate: Double
    public let schemaValidRate: Double
    public let fallbackRate: Double
    public let chronologyReport: ChronologyReport

    public init(
        totalItemCount: Int,
        processedItemCount: Int,
        pipelineCompletionRate: Double,
        schemaValidRate: Double,
        fallbackRate: Double,
        chronologyReport: ChronologyReport
    ) {
        self.totalItemCount = totalItemCount
        self.processedItemCount = processedItemCount
        self.pipelineCompletionRate = pipelineCompletionRate
        self.schemaValidRate = schemaValidRate
        self.fallbackRate = fallbackRate
        self.chronologyReport = chronologyReport
    }
}

public enum FeasibilityBenchmarkRunner {
    public static func run(entries: [FeedEntry], pipeline: BaselinePipeline) -> FeasibilityBenchmarkResult {
        let output = pipeline.process(entries: entries)

        let totalItemCount = entries.count
        let processedItemCount = output.items.count
        let pipelineCompletionRate = safeRatio(numerator: processedItemCount, denominator: totalItemCount)

        let schemaValidCount = output.items.filter {
            $0.category.isEmpty == false && $0.groupID.isEmpty == false
        }.count
        let schemaValidRate = safeRatio(numerator: schemaValidCount, denominator: totalItemCount)

        let fallbackCount = output.items.filter { $0.categorySource == .fallback }.count
        let fallbackRate = safeRatio(numerator: fallbackCount, denominator: max(1, processedItemCount))

        return FeasibilityBenchmarkResult(
            totalItemCount: totalItemCount,
            processedItemCount: processedItemCount,
            pipelineCompletionRate: pipelineCompletionRate,
            schemaValidRate: schemaValidRate,
            fallbackRate: fallbackRate,
            chronologyReport: output.chronologyReport
        )
    }

    private static func safeRatio(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }

        return Double(numerator) / Double(denominator)
    }
}
