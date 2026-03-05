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
        let storyPairLabels = try loadStoryPairLabels(from: options.storyLabelsPath)
        let taxonomyLabels = try loadTaxonomyLabels(from: options.taxonomyLabelsPath)
        let taxonomyManifest = try loadTaxonomyManifest(
            from: options.taxonomyManifestPath,
            taxonomyVersion: options.taxonomyVersion,
            taxonomyLabels: taxonomyLabels
        )

        let localLLMCategorizer = LocalLLMCommandCategorizer(
            command: options.localLLMCommand,
            taxonomyVersion: options.taxonomyVersion,
            taxonomyCategories: taxonomyManifest.orderedCategories,
            maxLabels: options.maxCategoryLabels
        )

        let pipeline = BaselinePipeline(
            categorizer: localLLMCategorizer,
            fallbackCategory: "unsorted",
            confidenceThreshold: 0.6,
            hierarchy: TaxonomyHierarchy(ancestorsByCategory: taxonomyManifest.ancestorsByCategory)
        )

        let started = DispatchTime.now()
        let result = FeasibilityBenchmarkRunner.run(
            entries: entries,
            pipeline: pipeline,
            storyPairLabels: storyPairLabels,
            taxonomyLabels: taxonomyLabels
        )
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
            groupPurity: result.groupingQuality.groupPurity,
            splitRate: result.groupingQuality.splitRate,
            overmergeRate: result.groupingQuality.overmergeRate,
            crossCategoryContradictionMergeRate: result.groupingQuality.crossCategoryContradictionMergeRate,
            evaluatedStoryPairCount: result.groupingQuality.evaluatedPairCount,
            microF1: result.categorizationQuality.microF1,
            macroF1: result.categorizationQuality.macroF1,
            jaccardScore: result.categorizationQuality.jaccardScore,
            evaluatedTaxonomyItemCount: result.categorizationQuality.evaluatedItemCount,
            hierarchyConstrainedItemCount: result.hierarchyQuality.constrainedItemCount,
            ancestorConsistencyRate: result.hierarchyQuality.ancestorConsistencyRate,
            wrongPropagatedCategoryRate: result.hierarchyQuality.wrongPropagatedCategoryRate,
            hierarchyDepthCoverage: result.hierarchyQuality.hierarchyDepthCoverage,
            perCategoryF1: result.categorizationQuality.perCategoryF1,
            processingDurationSeconds: durationSeconds,
            p95OfflineProcessingTimeSecondsPerItem: perItemSeconds,
            p99OfflineProcessingTimeSecondsPerItem: perItemSeconds
        )

        let runtimeManifest = RuntimeManifestPayload(
            runID: options.runID,
            runtimeID: options.runtimeID,
            runtimeVersion: options.runtimeVersion,
            modelID: options.modelID,
            modelHash: options.modelHash,
            promptTemplateHash: options.promptTemplateHash,
            inferenceSettingsHash: options.inferenceSettingsHash,
            seed: options.seed,
            threadCount: options.threadCount,
            llmCommand: options.localLLMCommand,
            maxCategoryLabels: options.maxCategoryLabels
        )
        let chronology = ChronologyPayload(
            inversionCount: result.chronologyReport.inversionCount,
            adjacentPairCount: result.chronologyReport.adjacentPairCount,
            inversionRate: result.chronologyReport.inversionRate
        )
        let grouping = GroupingPayload(
            evaluatedPairCount: result.groupingQuality.evaluatedPairCount,
            sameStoryPairCount: result.groupingQuality.sameStoryPairCount,
            differentStoryPairCount: result.groupingQuality.differentStoryPairCount,
            groupPurity: result.groupingQuality.groupPurity,
            splitRate: result.groupingQuality.splitRate,
            overmergeRate: result.groupingQuality.overmergeRate,
            crossCategoryContradictionMergeRate: result.groupingQuality.crossCategoryContradictionMergeRate
        )
        let hierarchy = HierarchyPayload(
            evaluatedItemCount: result.hierarchyQuality.evaluatedItemCount,
            constrainedItemCount: result.hierarchyQuality.constrainedItemCount,
            ancestorConsistencyRate: result.hierarchyQuality.ancestorConsistencyRate,
            wrongPropagatedCategoryRate: result.hierarchyQuality.wrongPropagatedCategoryRate,
            hierarchyDepthCoverage: result.hierarchyQuality.hierarchyDepthCoverage
        )

        try writeJSON(manifest, to: path(options.outputPath, "dataset-manifest.json"))
        try writeJSON(runtimeManifest, to: path(options.outputPath, "runtime-manifest.json"))
        try writeJSON(taxonomyManifest, to: path(options.outputPath, "taxonomy-v2-manifest.json"))
        try writeJSON(metrics, to: path(options.outputPath, "metrics.json"))
        try writeJSON(chronology, to: path(options.outputPath, "chronology-report.json"))
        try writeJSON(grouping, to: path(options.outputPath, "grouping-report.json"))
        try writeJSON(hierarchy, to: path(options.outputPath, "hierarchy-report.json"))
        try writeItemOutputHashes(result.processedItems, to: path(options.outputPath, "item-output-hashes.jsonl"))
        try copyArtifactFile(from: options.taxonomyLabelsPath, to: path(options.outputPath, "labels-taxonomy-v2.csv"))
        try copyArtifactFile(from: options.storyLabelsPath, to: path(options.outputPath, "labels-same-story.csv"))
        try writeDogfoodCorrectionsPlaceholder(to: path(options.outputPath, "dogfood-corrections.csv"))
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

    private static func loadStoryPairLabels(from path: String) throws -> [StoryPairLabel] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lines = raw
            .split(whereSeparator: \ .isNewline)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        guard lines.isEmpty == false else {
            return []
        }

        let records = lines.dropFirst()
        var labels: [StoryPairLabel] = []
        labels.reserveCapacity(records.count)

        for record in records {
            let parts = record.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  let pairType = StoryPairType(rawValue: parts[2].trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                continue
            }

            let itemIDA = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let itemIDB = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            labels.append(StoryPairLabel(itemIDA: itemIDA, itemIDB: itemIDB, label: pairType))
        }

        return labels
    }

    private static func loadTaxonomyLabels(from path: String) throws -> [TaxonomyLabel] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let lines = raw
            .split(whereSeparator: \ .isNewline)
            .map(String.init)
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

        guard lines.isEmpty == false else {
            return []
        }

        let records = lines.dropFirst()
        var labels: [TaxonomyLabel] = []
        labels.reserveCapacity(records.count)

        for record in records {
            let parts = record.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else {
                continue
            }

            let itemID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let categoryField = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            for category in parseTaxonomyCategoriesField(categoryField) {
                labels.append(TaxonomyLabel(itemID: itemID, category: category))
            }
        }

        return labels
    }

    private static func parseTaxonomyCategoriesField(_ field: String) -> [String] {
        field
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func loadTaxonomyManifest(
        from path: String?,
        taxonomyVersion: String,
        taxonomyLabels: [TaxonomyLabel]
    ) throws -> TaxonomyV2Manifest {
        let fallbackCategories = Array(Set(taxonomyLabels.map { $0.category })).sorted()

        guard let path, path.isEmpty == false else {
            return TaxonomyV2Manifest(
                taxonomyVersion: taxonomyVersion,
                ancestorsByCategory: [:],
                orderedCategories: fallbackCategories
            )
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var manifest = try JSONDecoder().decode(TaxonomyV2Manifest.self, from: data)
        if manifest.taxonomyVersion.isEmpty {
            manifest.taxonomyVersion = taxonomyVersion
        }

        if manifest.orderedCategories.isEmpty {
            manifest.orderedCategories = fallbackCategories
        }

        return manifest
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

    private static func writeDogfoodCorrectionsPlaceholder(to filePath: String) throws {
        let header = "item_id,reviewed,corrected,reason\n"
        try header.write(to: URL(fileURLWithPath: filePath), atomically: true, encoding: .utf8)
    }

    private static func copyArtifactFile(from sourcePath: String, to destinationPath: String) throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        if fileManager.fileExists(atPath: destinationPath) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private static func writeItemOutputHashes(_ items: [ProcessedItem], to filePath: String) throws {
        let formatter = ISO8601DateFormatter()
        let lines: [String] = items.map { item in
            let canonicalTimestamp = formatter.string(from: item.canonicalTimestamp)
            let canonical = [
                item.id,
                canonicalTimestamp,
                item.groupID,
                item.categories.joined(separator: ","),
                item.categorySource == .model ? "model" : "fallback",
            ].joined(separator: "|")

            let hash = fnv1a64Hex(canonical)
            return "{\"item_id\":\"\(item.id)\",\"hash\":\"\(hash)\"}"
        }

        try lines.joined(separator: "\n").appending("\n").write(
            to: URL(fileURLWithPath: filePath),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func fnv1a64Hex(_ input: String) -> String {
        let bytes = Array(input.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        return String(format: "%016llx", hash)
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
        - Group purity: \(metrics.groupPurity)
        - Split rate: \(metrics.splitRate)
        - Overmerge rate: \(metrics.overmergeRate)
        - Cross-category contradiction merge rate: \(metrics.crossCategoryContradictionMergeRate)
        - Micro F1: \(metrics.microF1)
        - Macro F1: \(metrics.macroF1)
        - Jaccard score: \(metrics.jaccardScore)
        - Ancestor consistency rate: \(metrics.ancestorConsistencyRate)
        - Wrong propagated category rate: \(metrics.wrongPropagatedCategoryRate)
        - Hierarchy depth coverage: \(metrics.hierarchyDepthCoverage)

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
        - Next step: Evaluate artifacts against docs/quality-gates/2026-03-01-feasibility-spike-v2-multilabel-local-llm-gate-check.md
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
            return "usage: swift run rss-spike benchmark --dataset <path> --taxonomy-labels <path> --story-labels <path> --taxonomy-version <v> --guideline-version <v> --hardware-profile <profile> --llm-command <command> [--taxonomy-manifest <path>] [--max-category-labels <n>] [--runtime-id <id>] [--runtime-version <version>] [--model-id <id>] [--model-hash <hash>] [--prompt-template-hash <hash>] [--inference-settings-hash <hash>] [--seed <n>] [--threads <n>] --output <path>"
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
    let taxonomyManifestPath: String?
    let taxonomyVersion: String
    let guidelineVersion: String
    let hardwareProfile: String
    let localLLMCommand: String
    let maxCategoryLabels: Int
    let runtimeID: String
    let runtimeVersion: String
    let modelID: String
    let modelHash: String
    let promptTemplateHash: String
    let inferenceSettingsHash: String
    let seed: Int
    let threadCount: Int
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
        let taxonomyManifestPath = values["--taxonomy-manifest"]
        let taxonomyVersion = try require("--taxonomy-version", values)
        let guidelineVersion = try require("--guideline-version", values)
        let hardwareProfile = try require("--hardware-profile", values)
        let localLLMCommand = try require("--llm-command", values)
        let maxCategoryLabels = parseInt(values["--max-category-labels"], defaultValue: 3)
        let runtimeID = values["--runtime-id"] ?? "local-llm"
        let runtimeVersion = values["--runtime-version"] ?? "unknown"
        let modelID = values["--model-id"] ?? "unknown"
        let modelHash = values["--model-hash"] ?? "unknown"
        let promptTemplateHash = values["--prompt-template-hash"] ?? "unknown"
        let inferenceSettingsHash = values["--inference-settings-hash"] ?? "unknown"
        let seed = parseInt(values["--seed"], defaultValue: 0)
        let threadCount = parseInt(values["--threads"], defaultValue: 1)
        let outputPath = try require("--output", values)
        let runID = DateFormatter.runID.string(from: Date())

        return CLIOptions(
            datasetPath: datasetPath,
            taxonomyLabelsPath: taxonomyLabelsPath,
            storyLabelsPath: storyLabelsPath,
            taxonomyManifestPath: taxonomyManifestPath,
            taxonomyVersion: taxonomyVersion,
            guidelineVersion: guidelineVersion,
            hardwareProfile: hardwareProfile,
            localLLMCommand: localLLMCommand,
            maxCategoryLabels: max(1, maxCategoryLabels),
            runtimeID: runtimeID,
            runtimeVersion: runtimeVersion,
            modelID: modelID,
            modelHash: modelHash,
            promptTemplateHash: promptTemplateHash,
            inferenceSettingsHash: inferenceSettingsHash,
            seed: seed,
            threadCount: max(1, threadCount),
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

    private static func parseInt(_ value: String?, defaultValue: Int) -> Int {
        guard let value,
              let parsed = Int(value)
        else {
            return defaultValue
        }

        return parsed
    }
}

private struct JSONLEntry: Decodable {
    let id: String
    let sourceID: String
    let title: String
    let summary: String
    let body: String?
    let publishedAt: Double?
    let updatedAt: Double?
    let fetchedAt: Double?

    var asFeedEntry: FeedEntry {
        FeedEntry(
            id: id,
            sourceID: sourceID,
            title: title,
            summary: summary,
            body: body,
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
        case body
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
    let groupPurity: Double
    let splitRate: Double
    let overmergeRate: Double
    let crossCategoryContradictionMergeRate: Double
    let evaluatedStoryPairCount: Int
    let microF1: Double
    let macroF1: Double
    let jaccardScore: Double
    let evaluatedTaxonomyItemCount: Int
    let hierarchyConstrainedItemCount: Int
    let ancestorConsistencyRate: Double
    let wrongPropagatedCategoryRate: Double
    let hierarchyDepthCoverage: Double
    let perCategoryF1: [String: Double]
    let processingDurationSeconds: Double
    let p95OfflineProcessingTimeSecondsPerItem: Double
    let p99OfflineProcessingTimeSecondsPerItem: Double
}

private struct ChronologyPayload: Encodable {
    let inversionCount: Int
    let adjacentPairCount: Int
    let inversionRate: Double
}

private struct GroupingPayload: Encodable {
    let evaluatedPairCount: Int
    let sameStoryPairCount: Int
    let differentStoryPairCount: Int
    let groupPurity: Double
    let splitRate: Double
    let overmergeRate: Double
    let crossCategoryContradictionMergeRate: Double
}

private struct HierarchyPayload: Encodable {
    let evaluatedItemCount: Int
    let constrainedItemCount: Int
    let ancestorConsistencyRate: Double
    let wrongPropagatedCategoryRate: Double
    let hierarchyDepthCoverage: Double
}

private struct TaxonomyV2Manifest: Codable {
    var taxonomyVersion: String
    var ancestorsByCategory: [String: [String]]
    var orderedCategories: [String]

    init(taxonomyVersion: String, ancestorsByCategory: [String: [String]], orderedCategories: [String]) {
        self.taxonomyVersion = taxonomyVersion
        self.ancestorsByCategory = ancestorsByCategory
        self.orderedCategories = orderedCategories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taxonomyVersion = try container.decodeIfPresent(String.self, forKey: .taxonomyVersion) ?? ""
        ancestorsByCategory = try container.decodeIfPresent([String: [String]].self, forKey: .ancestorsByCategory) ?? [:]
        orderedCategories = try container.decodeIfPresent([String].self, forKey: .orderedCategories) ?? []
    }
}

private struct RuntimeManifestPayload: Encodable {
    let runID: String
    let runtimeID: String
    let runtimeVersion: String
    let modelID: String
    let modelHash: String
    let promptTemplateHash: String
    let inferenceSettingsHash: String
    let seed: Int
    let threadCount: Int
    let llmCommand: String
    let maxCategoryLabels: Int
}

private struct LocalLLMCommandCategorizer: EntryCategorizer {
    let command: String
    let taxonomyVersion: String
    let taxonomyCategories: [String]
    let maxLabels: Int

    func predict(for entry: FeedEntry) -> CategoryPrediction? {
        guard command.isEmpty == false else {
            return nil
        }

        let request = LocalLLMRequest(
            itemID: entry.id,
            title: entry.title,
            summary: entry.summary,
            body: entry.body,
            taxonomyVersion: taxonomyVersion,
            candidateCategories: taxonomyCategories,
            maxLabels: maxLabels
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let requestData = try encoder.encode(request)
            guard let responseData = runLLMCommand(command: command, requestData: requestData) else {
                return nil
            }

            let response = try JSONDecoder().decode(LocalLLMResponse.self, from: responseData)
            let scores = response.scores
                .map { CategoryScore(label: $0.label, confidence: $0.confidence) }
                .filter { $0.label.isEmpty == false }

            guard scores.isEmpty == false else {
                return nil
            }

            return CategoryPrediction(scores: scores, storyKey: response.storyKey)
        } catch {
            return nil
        }
    }

    private func runLLMCommand(command: String, requestData: Data) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", command]

        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(requestData)
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            return outputPipe.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }
}

private struct LocalLLMRequest: Encodable {
    let itemID: String
    let title: String
    let summary: String
    let body: String?
    let taxonomyVersion: String
    let candidateCategories: [String]
    let maxLabels: Int

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case title
        case summary
        case body
        case taxonomyVersion = "taxonomy_version"
        case candidateCategories = "candidate_categories"
        case maxLabels = "max_labels"
    }
}

private struct LocalLLMResponse: Decodable {
    let scores: [LocalLLMScore]
    let storyKey: String?

    enum CodingKeys: String, CodingKey {
        case labels
        case categories
        case category
        case confidence
        case storyKey = "story_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storyKey = try container.decodeIfPresent(String.self, forKey: .storyKey)

        if let labels = try container.decodeIfPresent([LocalLLMScore].self, forKey: .labels),
           labels.isEmpty == false {
            scores = labels
            return
        }

        if let categories = try container.decodeIfPresent([LocalLLMScore].self, forKey: .categories),
           categories.isEmpty == false {
            scores = categories
            return
        }

        if let category = try container.decodeIfPresent(String.self, forKey: .category),
           let confidence = Self.decodeConfidence(from: container) {
            scores = [LocalLLMScore(label: category, confidence: confidence)]
            return
        }

        scores = []
    }

    private static func decodeConfidence(from container: KeyedDecodingContainer<CodingKeys>) -> Double? {
        if let numeric = try? container.decodeIfPresent(Double.self, forKey: .confidence) {
            return numeric
        }

        if let text = try? container.decodeIfPresent(String.self, forKey: .confidence),
           let numeric = Double(text) {
            return numeric
        }

        return nil
    }
}

private struct LocalLLMScore: Decodable {
    let label: String
    let confidence: Double

    init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case label
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)

        if let numeric = try? container.decode(Double.self, forKey: .confidence) {
            confidence = numeric
            return
        }

        if let text = try? container.decode(String.self, forKey: .confidence),
           let numeric = Double(text) {
            confidence = numeric
            return
        }

        confidence = 0
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
