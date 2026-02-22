import Foundation
import RSSSpikeCore

@main
struct RSSSpikeCLI {
    static func main() {
        do {
            try run(arguments: CommandLine.arguments)
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.usage
        }

        let command = arguments[1]
        switch command {
        case "benchmark":
            let options = try CLIOptions.parse(Array(arguments.dropFirst(2)))
            try runBenchmark(options: options)
        default:
            throw CLIError.usage
        }
    }

    private static func runBenchmark(options: CLIOptions) throws {
        let runStartedAt = Date()
        let entries = try loadDataset(from: options.datasetPath)

        let pipeline = BaselinePipeline(
            categorizer: KeywordCategorizer(),
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6
        )

        let started = DispatchTime.now()
        let result = FeasibilityBenchmarkRunner.run(entries: entries, pipeline: pipeline)
        let ended = DispatchTime.now()
        let durationNs = ended.uptimeNanoseconds - started.uptimeNanoseconds
        let durationSeconds = Double(durationNs) / 1_000_000_000
        let perItemSeconds = result.processedItemCount > 0
            ? durationSeconds / Double(result.processedItemCount)
            : 0

        try FileManager.default.createDirectory(atPath: options.outputPath, withIntermediateDirectories: true)

        let manifest = DatasetManifest(
            runID: options.runID,
            datasetPath: options.datasetPath,
            taxonomyLabelsPath: options.taxonomyLabelsPath,
            storyLabelsPath: options.storyLabelsPath,
            taxonomyVersion: options.taxonomyVersion,
            guidelineVersion: options.guidelineVersion,
            hardwareProfile: options.hardwareProfile,
            itemCount: entries.count,
            runStartedAt: runStartedAt
        )
        let metrics = MetricsPayload(
            totalItemCount: result.totalItemCount,
            processedItemCount: result.processedItemCount,
            pipelineCompletionRate: result.pipelineCompletionRate,
            schemaValidRate: result.schemaValidRate,
            fallbackRate: result.fallbackRate,
            processingDurationSeconds: durationSeconds,
            p95OfflineProcessingTimeSecondsPerItem: perItemSeconds,
            p99OfflineProcessingTimeSecondsPerItem: perItemSeconds
        )
        let chronology = ChronologyPayload(
            inversionCount: result.chronologyReport.inversionCount,
            adjacentPairCount: result.chronologyReport.adjacentPairCount,
            inversionRate: result.chronologyReport.inversionRate
        )

        try writeJSON(manifest, to: path(options.outputPath, "dataset-manifest.json"))
        try writeJSON(metrics, to: path(options.outputPath, "metrics.json"))
        try writeJSON(chronology, to: path(options.outputPath, "chronology-report.json"))
        try writeMarkdown(errorAnalysisMarkdown(metrics: metrics), to: path(options.outputPath, "error-analysis.md"))
        try writeMarkdown(decisionLogMarkdown(runID: options.runID), to: path(options.outputPath, "decision-log.md"))

        print("benchmark complete")
        print("output: \(options.outputPath)")
    }

    private static func loadDataset(from path: String) throws -> [FeedEntry] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lines = raw
            .split(whereSeparator: \ .isNewline)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        let decoder = JSONDecoder()
        var entries: [FeedEntry] = []
        entries.reserveCapacity(lines.count)

        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            let row = try decoder.decode(JSONLEntry.self, from: data)
            entries.append(row.asFeedEntry)
        }

        return entries
    }

    private static func writeJSON<T: Encodable>(_ value: T, to filePath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: filePath))
    }

    private static func writeMarkdown(_ content: String, to filePath: String) throws {
        try content.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
    }

    private static func path(_ base: String, _ file: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(file).path
    }

    private static func errorAnalysisMarkdown(metrics: MetricsPayload) -> String {
        """
        # Error Analysis

        - Total items: \(metrics.totalItemCount)
        - Processed items: \(metrics.processedItemCount)
        - Pipeline completion rate: \(metrics.pipelineCompletionRate)
        - Fallback rate: \(metrics.fallbackRate)

        ## Notes

        - Investigate fallback-heavy categories first.
        - Review dropped items where canonical timestamp is missing.
        """
    }

    private static func decisionLogMarkdown(runID: String) -> String {
        """
        # Decision Log

        - Run ID: \(runID)
        - Status: PENDING
        - Decision: NO-GO until gate checklist is completed.
        - Next step: Evaluate artifacts against docs/quality-gates/2026-02-21-feasibility-spike-prebuild-gate-check.md
        """
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case missingOption(String)
    case invalidOption(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: swift run rss-spike benchmark --dataset <path> --taxonomy-labels <path> --story-labels <path> --taxonomy-version <v> --guideline-version <v> --hardware-profile <profile> --output <path>"
        case .missingOption(let option):
            return "missing required option: \(option)"
        case .invalidOption(let option):
            return "invalid option format: \(option)"
        }
    }
}

private struct CLIOptions {
    let datasetPath: String
    let taxonomyLabelsPath: String
    let storyLabelsPath: String
    let taxonomyVersion: String
    let guidelineVersion: String
    let hardwareProfile: String
    let outputPath: String
    let runID: String

    static func parse(_ args: [String]) throws -> CLIOptions {
        var values: [String: String] = [:]
        var index = 0
        while index < args.count {
            let key = args[index]
            guard key.hasPrefix("--") else {
                throw CLIError.invalidOption(key)
            }

            let valueIndex = index + 1
            guard valueIndex < args.count else {
                throw CLIError.invalidOption(key)
            }

            values[key] = args[valueIndex]
            index += 2
        }

        let datasetPath = try require("--dataset", values)
        let taxonomyLabelsPath = try require("--taxonomy-labels", values)
        let storyLabelsPath = try require("--story-labels", values)
        let taxonomyVersion = try require("--taxonomy-version", values)
        let guidelineVersion = try require("--guideline-version", values)
        let hardwareProfile = try require("--hardware-profile", values)
        let outputPath = try require("--output", values)
        let runID = DateFormatter.runID.string(from: Date())

        return CLIOptions(
            datasetPath: datasetPath,
            taxonomyLabelsPath: taxonomyLabelsPath,
            storyLabelsPath: storyLabelsPath,
            taxonomyVersion: taxonomyVersion,
            guidelineVersion: guidelineVersion,
            hardwareProfile: hardwareProfile,
            outputPath: outputPath,
            runID: runID
        )
    }

    private static func require(_ key: String, _ values: [String: String]) throws -> String {
        guard let value = values[key], value.isEmpty == false else {
            throw CLIError.missingOption(key)
        }

        return value
    }
}

private struct JSONLEntry: Decodable {
    let id: String
    let sourceID: String
    let title: String
    let summary: String
    let publishedAt: Double?
    let updatedAt: Double?
    let fetchedAt: Double?

    var asFeedEntry: FeedEntry {
        FeedEntry(
            id: id,
            sourceID: sourceID,
            title: title,
            summary: summary,
            publishedAt: publishedAt.map(Date.init(timeIntervalSince1970:)),
            updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:)),
            fetchedAt: fetchedAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID = "source_id"
        case title
        case summary
        case publishedAt = "published_at"
        case updatedAt = "updated_at"
        case fetchedAt = "fetched_at"
    }
}

private struct DatasetManifest: Encodable {
    let runID: String
    let datasetPath: String
    let taxonomyLabelsPath: String
    let storyLabelsPath: String
    let taxonomyVersion: String
    let guidelineVersion: String
    let hardwareProfile: String
    let itemCount: Int
    let runStartedAt: Date
}

private struct MetricsPayload: Encodable {
    let totalItemCount: Int
    let processedItemCount: Int
    let pipelineCompletionRate: Double
    let schemaValidRate: Double
    let fallbackRate: Double
    let processingDurationSeconds: Double
    let p95OfflineProcessingTimeSecondsPerItem: Double
    let p99OfflineProcessingTimeSecondsPerItem: Double
}

private struct ChronologyPayload: Encodable {
    let inversionCount: Int
    let adjacentPairCount: Int
    let inversionRate: Double
}

private struct KeywordCategorizer: EntryCategorizer {
    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        let text = "\(entry.title) \(entry.summary)".lowercased()
        if text.contains("apple") || text.contains("mac") || text.contains("iphone") {
            return CategoryPrediction(label: "apple", confidence: 0.9)
        }
        if text.contains("openai") || text.contains("ai") || text.contains("llm") {
            return CategoryPrediction(label: "ai", confidence: 0.85)
        }
        if text.contains("security") || text.contains("vulnerability") {
            return CategoryPrediction(label: "security", confidence: 0.8)
        }

        return CategoryPrediction(label: "general", confidence: 0.55)
    }
}

private extension DateFormatter {
    static let runID: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
