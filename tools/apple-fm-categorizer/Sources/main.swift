import Foundation
import FoundationModels
import NaturalLanguage

// MARK: - Data types for input/output

struct QueueItem: Codable {
    let id: String
    let source_id: String?
    let title: String
    let summary: String?
    let body: String?
    let link: String?
}

struct PredictionOutput: Codable {
    let item_id: String
    let source_id: String
    let title: String
    let labels: [LabelOutput]
    let story_key: String
    let latency_ms: Int
    let error: String?
}

struct LabelOutput: Codable {
    let label: String
    let confidence: Double
}

// MARK: - Generable types for Apple Foundation Models

@Generable
enum CategoryLabel: String, CaseIterable {
    case technology
    case apple
    case tesla
    case ai
    case home_automation
    case gaming
    case gaming_industry
    case playstation_5
    case world
    case other
}

@Generable
struct ArticleClassification {
    @Guide(description: "All categories that match this article. Most articles match 2-3 categories. Include broad categories like technology alongside specific ones. Use other alone only if nothing else fits.", .count(1...3))
    var categories: [CategoryLabel]

    @Guide(description: "A short stable kebab-case topic key for story grouping, e.g. 'apple-m5-macbook-pro' or 'resident-evil-requiem'")
    var storyKey: String
}

// MARK: - Main

@main
struct AppleFMCategorizer {
    static func main() async throws {
        let args = CommandLine.arguments
        
        guard args.count >= 3 else {
            printStderr("Usage: apple-fm-categorizer <items.jsonl> <output-dir> [--adapter contentTagging|default] [--greedy]")
            Foundation.exit(1)
        }
        
        let inputPath = args[1]
        let outputDir = args[2]
        
        var useContentTagging = false
        var useGreedy = false
        
        for arg in args[3...] {
            if arg == "--adapter" || arg == "contentTagging" {
                // Handle --adapter contentTagging
                if arg == "contentTagging" { useContentTagging = true }
            }
            if arg == "--greedy" { useGreedy = true }
        }
        
        // Simple flag parsing
        if args.contains("--content-tagging") { useContentTagging = true }
        if args.contains("--greedy") { useGreedy = true }
        
        // Check model availability
        let model = useContentTagging
            ? SystemLanguageModel(useCase: .contentTagging)
            : SystemLanguageModel.default
        
        guard case .available = model.availability else {
            printStderr("ERROR: Apple Foundation Model is not available on this device.")
            if case .unavailable(let reason) = model.availability {
                printStderr("Reason: \(reason)")
            }
            Foundation.exit(1)
        }
        
        printStderr("Model available. Content tagging adapter: \(useContentTagging). Greedy: \(useGreedy)")
        
        // Load items
        let items = try loadItems(path: inputPath)
        printStderr("Loaded \(items.count) items from \(inputPath)")
        
        // Create output directory
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        
        // Process items
        var predictions: [PredictionOutput] = []
        var labelCounts: [String: Int] = [:]
        var fallbackCount = 0
        var errorCount = 0
        
        // Category descriptions match config/categories-v1.yaml
        // In production, these come from user-defined category settings
        let categoryDescriptions = """
            Categories:
            - technology: A broad category for all news about technology companies, products, platforms, and innovations. This includes news about Apple, Tesla, AI companies, and any other tech company. Use alongside more specific categories when applicable.
            - apple: All news about Apple company, its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series), services, and innovations. Apple news is always also technology news.
            - tesla: All news related to Tesla company, its vehicles, energy products, and innovations. Tesla news is always also technology news.
            - ai: Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies like OpenAI or Anthropic, and applied generative AI. Do not apply when a product merely uses AI as a feature.
            - home_automation: Smart home devices, home automation platforms (Google Home, Apple HomeKit, Amazon Alexa), Matter protocol, and related IoT technologies for the home.
            - gaming: Game releases, game reviews, gameplay content, game announcements, and game-specific news. For business news about the gaming industry (layoffs, acquisitions, financial results), use 'gaming_industry' instead.
            - gaming_industry: Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes. Use this instead of 'gaming' when the article is about the business side rather than games themselves.
            - playstation_5: All news specifically about PlayStation 5 games, hardware, and ecosystem. Exclude mobile gaming, PC gaming, and other console news, which should be categorized under 'gaming'.
            - world: Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries.
            - other: Use only when no other category clearly matches. Never combine with another category.
            """
        
        let instructions = """
            Categorize the following article into the user-defined categories listed below.
            Assign all categories that clearly match the article's content.
            When a specific category applies, also assign any broader category that encompasses it.
            Only assign a category when the article content provides clear evidence for it.
            
            \(categoryDescriptions)
            """
        
        var skippedLanguageCount = 0
        
        for (index, item) in items.enumerated() {
            let startTime = DispatchTime.now()
            
            // Language detection: skip non-English articles
            let textForDetection = "\(item.title) \(item.body ?? item.summary ?? "")"
            let detectedLang = detectLanguage(textForDetection)
            
            if detectedLang != "en" {
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let latencyMs = Int(elapsed / 1_000_000)
                
                let prediction = PredictionOutput(
                    item_id: item.id,
                    source_id: item.source_id ?? "",
                    title: item.title,
                    labels: [LabelOutput(label: "other", confidence: 0.0)],
                    story_key: normalizeStoryKey(item.title),
                    latency_ms: latencyMs,
                    error: "skipped_language:\(detectedLang)"
                )
                predictions.append(prediction)
                fallbackCount += 1
                skippedLanguageCount += 1
                labelCounts["other", default: 0] += 1
                printStderr("[\(index + 1)/\(items.count)] \(item.id): SKIPPED (lang=\(detectedLang)) \(item.title.prefix(60))")
                continue
            }
            
            let session = LanguageModelSession(
                model: model,
                instructions: instructions
            )
            
            let prompt = buildPrompt(item: item)
            
            var prediction: PredictionOutput
            
            do {
                let options = useGreedy
                    ? GenerationOptions(sampling: .greedy)
                    : GenerationOptions()
                
                let response = try await session.respond(
                    to: prompt,
                    generating: ArticleClassification.self,
                    options: options
                )
                
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let latencyMs = Int(elapsed / 1_000_000)
                
                let classification = response.content
                let labels = classification.categories.map { cat in
                    LabelOutput(label: cat.rawValue, confidence: 0.8)
                }
                
                prediction = PredictionOutput(
                    item_id: item.id,
                    source_id: item.source_id ?? "",
                    title: item.title,
                    labels: labels.isEmpty ? [LabelOutput(label: "other", confidence: 0.0)] : labels,
                    story_key: normalizeStoryKey(classification.storyKey),
                    latency_ms: latencyMs,
                    error: nil
                )
                
                // Count labels
                for label in labels {
                    labelCounts[label.label, default: 0] += 1
                }
                if labels.count == 1 && labels[0].label == "other" {
                    fallbackCount += 1
                }
                
            } catch {
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let latencyMs = Int(elapsed / 1_000_000)
                
                prediction = PredictionOutput(
                    item_id: item.id,
                    source_id: item.source_id ?? "",
                    title: item.title,
                    labels: [LabelOutput(label: "other", confidence: 0.0)],
                    story_key: normalizeStoryKey(item.title),
                    latency_ms: latencyMs,
                    error: "\(error)"
                )
                errorCount += 1
                fallbackCount += 1
                labelCounts["other", default: 0] += 1
            }
            
            predictions.append(prediction)
            printStderr("[\(index + 1)/\(items.count)] \(item.id): \(prediction.labels.map(\.label)) (\(prediction.latency_ms)ms)\(prediction.error != nil ? " ERROR: \(prediction.error!)" : "")")
        }
        
        // Write predictions
        let predictionsPath = "\(outputDir)/predictions.jsonl"
        let predictionsData = predictions.map { pred -> String in
            let data = try! JSONEncoder().encode(pred)
            return String(data: data, encoding: .utf8)!
        }.joined(separator: "\n") + "\n"
        try predictionsData.write(toFile: predictionsPath, atomically: true, encoding: .utf8)
        
        // Write metrics
        let metrics: [String: Any] = [
            "run_started_at": ISO8601DateFormatter().string(from: Date()),
            "dataset_path": inputPath,
            "model": useContentTagging ? "apple-fm-content-tagging" : "apple-fm-default",
            "greedy": useGreedy,
            "total_items": items.count,
            "categorized_items": items.count,
            "fallback_count": fallbackCount,
            "fallback_rate": items.count > 0 ? Double(fallbackCount) / Double(items.count) : 0.0,
            "error_count": errorCount,
            "label_counts": labelCounts,
        ]
        let metricsJSON = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try metricsJSON.write(to: URL(fileURLWithPath: "\(outputDir)/metrics.json"))
        
        printStderr("Done. \(items.count) items processed, \(errorCount) errors, \(skippedLanguageCount) skipped (non-English), fallback rate: \(String(format: "%.3f", Double(fallbackCount) / Double(max(1, items.count))))")
    }
}

// MARK: - Helpers

func printStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func loadItems(path: String) throws -> [QueueItem] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    return content.split(separator: "\n").compactMap { line -> QueueItem? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? decoder.decode(QueueItem.self, from: Data(trimmed.utf8))
    }
}

func buildPrompt(item: QueueItem) -> String {
    let title = item.title
    let summary = item.summary ?? ""
    var body = item.body ?? ""
    
    // Truncate body to avoid exceeding context window.
    // Apple FM context window is limited; keep body under ~8K chars (~2K tokens)
    // to leave room for instructions, categories, and output.
    let maxBodyChars = 8000
    if body.count > maxBodyChars {
        body = String(body.prefix(maxBodyChars)) + "... (truncated)"
    }
    
    return """
        title: \(title)
        summary: \(summary)
        body: \(body)
        """
}

func detectLanguage(_ text: String) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue ?? "unknown"
}

func normalizeStoryKey(_ value: String) -> String {
    let lowered = value.lowercased()
    let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "story-unknown" : String(trimmed.prefix(80))
}
