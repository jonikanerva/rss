import Foundation
import FoundationModels
import NaturalLanguage
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

// MARK: - Generable output type

/// Output structure for Apple Foundation Models classification.
/// Uses string arrays since categories are user-defined at runtime.
@Generable
struct ArticleClassification {
    @Guide(description: "All category labels that match this article. Most articles match 1-3 categories. Include broad categories alongside specific ones. Use 'other' alone only if nothing else fits.", .count(1...4))
    var categories: [String]

    @Guide(description: "A short stable kebab-case topic key for story grouping, e.g. 'apple-m5-macbook-pro' or 'openai-dod-contract'")
    var storyKey: String
}

// MARK: - Sendable DTO for crossing actor boundaries

/// Lightweight struct carrying classification input data across actor boundaries.
private nonisolated struct ClassificationInput: Sendable {
    let entryID: Int
    let title: String
    let summary: String
    let body: String
}

/// Lightweight struct carrying classification results back to the main actor.
private nonisolated struct ClassificationResult: Sendable {
    let entryID: Int
    let categoryLabels: [String]
    let storyKey: String
    let detectedLanguage: String
}

// MARK: - Pure helper functions (nonisolated, safe to call from any context)

private nonisolated func stripHTML(_ html: String) -> String {
    guard !html.isEmpty else { return "" }
    var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "&amp;", with: "&")
    text = text.replacingOccurrences(of: "&lt;", with: "<")
    text = text.replacingOccurrences(of: "&gt;", with: ">")
    text = text.replacingOccurrences(of: "&quot;", with: "\"")
    text = text.replacingOccurrences(of: "&#39;", with: "'")
    text = text.replacingOccurrences(of: "&nbsp;", with: " ")
    text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func detectLanguage(_ text: String) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue ?? "unknown"
}

private nonisolated func normalizeStoryKey(_ value: String) -> String {
    let lowered = value.lowercased()
    let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "story-unknown" : String(trimmed.prefix(80))
}

// MARK: - Classification Engine

/// Classifies articles using Apple Foundation Models with user-defined categories.
/// Runs as a continuous polling loop alongside fetch, or as a one-shot call.
@MainActor
@Observable
final class ClassificationEngine {
    private(set) var isClassifying = false
    private(set) var progress: String = ""
    private(set) var classifiedCount = 0
    private(set) var totalToClassify = 0

    private var classificationTask: Task<Void, Never>?

    // MARK: - Continuous classification (polling loop)

    /// Start a long-lived classification loop that polls for unclassified entries.
    /// Runs alongside fetch — as articles arrive, they get classified automatically.
    func startContinuousClassification(in context: ModelContext) {
        classificationTask?.cancel()
        classificationTask = Task {
            while !Task.isCancelled {
                await classifyNextBatch(in: context)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(2))
            }
            isClassifying = false
            progress = ""
        }
    }

    /// Stop the continuous classification loop.
    func stopContinuousClassification() {
        classificationTask?.cancel()
        classificationTask = nil
    }

    // MARK: - One-shot classification (manual sync button)

    /// Classify all unclassified entries as a one-shot operation.
    func classifyUnclassified(in context: ModelContext) async {
        await classifyNextBatch(in: context)
    }

    /// Reclassify all entries (e.g., after category changes).
    func reclassifyAll(in context: ModelContext) async {
        let descriptor = FetchDescriptor<Entry>()
        if let entries = try? context.fetch(descriptor) {
            for entry in entries {
                entry.categoryLabels = []
                entry.storyKey = nil
                entry.detectedLanguage = nil
                entry.isClassified = false
            }
            try? context.save()
        }
        await classifyNextBatch(in: context)
    }

    // MARK: - Core classification logic

    /// Fetch and classify one batch of unclassified entries.
    /// Returns when all currently unclassified entries are processed or on error.
    private func classifyNextBatch(in context: ModelContext) async {
        // Fetch user-defined categories
        var categoryDescriptor = FetchDescriptor<Category>()
        categoryDescriptor.sortBy = [SortDescriptor(\Category.sortOrder)]
        guard let categories = try? context.fetch(categoryDescriptor),
              !categories.isEmpty else {
            return
        }

        // Fetch unclassified entries
        let entryDescriptor = FetchDescriptor<Entry>(
            predicate: #Predicate<Entry> { !$0.isClassified },
            sortBy: [SortDescriptor(\Entry.createdAt, order: .reverse)]
        )
        guard let entries = try? context.fetch(entryDescriptor),
              !entries.isEmpty else {
            if isClassifying {
                isClassifying = false
                progress = ""
            }
            return
        }

        // Check model availability
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            logger.error("Apple Foundation Model not available")
            return
        }

        isClassifying = true
        totalToClassify = entries.count
        classifiedCount = 0
        logger.info("Classifying \(entries.count) entries with \(categories.count) categories")

        let inputs: [ClassificationInput] = entries.map { entry in
            ClassificationInput(
                entryID: entry.feedbinEntryID,
                title: entry.title ?? "Untitled",
                summary: entry.summary ?? "",
                body: entry.bestBody
            )
        }

        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.feedbinEntryID, $0) })
        let instructions = buildInstructions(from: categories)
        let validLabels = Set(categories.map { $0.label })

        var skippedNonEnglish = 0
        var classifiedOK = 0

        for input in inputs {
            if Task.isCancelled { break }

            // All heavy work (preprocessing + FM inference) on background thread
            let classificationResult = await Task.detached(priority: .utility) {
                let textForDetection = "\(input.title) \(stripHTML(input.body).prefix(500))"
                let lang = detectLanguage(textForDetection)
                let strippedBody = stripHTML(input.body)

                if lang != "en" {
                    return ClassificationResult(
                        entryID: input.entryID,
                        categoryLabels: ["other"],
                        storyKey: normalizeStoryKey(input.title),
                        detectedLanguage: lang
                    )
                }

                // FM inference — LanguageModelSession is not MainActor-bound
                do {
                    let session = LanguageModelSession(model: model, instructions: instructions)
                    var body = strippedBody
                    if body.count > 2000 { body = String(body.prefix(2000)) + "..." }
                    let prompt = """
                        title: \(input.title)
                        summary: \(input.summary)
                        body: \(body)
                        """
                    let options = GenerationOptions(sampling: .greedy)
                    let response = try await session.respond(
                        to: prompt,
                        generating: ArticleClassification.self,
                        options: options
                    )
                    let classification = response.content
                    var labels = classification.categories.filter { validLabels.contains($0) }
                    if labels.isEmpty { labels = ["other"] }
                    let storyKey = normalizeStoryKey(classification.storyKey)
                    return ClassificationResult(
                        entryID: input.entryID,
                        categoryLabels: labels,
                        storyKey: storyKey,
                        detectedLanguage: lang
                    )
                } catch {
                    return ClassificationResult(
                        entryID: input.entryID,
                        categoryLabels: ["other"],
                        storyKey: normalizeStoryKey(input.title),
                        detectedLanguage: lang
                    )
                }
            }.value

            // Apply result back to SwiftData on MainActor (fast, just property writes)
            guard let entry = entriesByID[classificationResult.entryID] else { continue }
            entry.detectedLanguage = classificationResult.detectedLanguage
            entry.categoryLabels = classificationResult.categoryLabels
            entry.storyKey = classificationResult.storyKey
            entry.isClassified = true

            classifiedCount += 1
            progress = "Categorizing \(classifiedCount)/\(totalToClassify)"

            if classificationResult.categoryLabels == ["other"] && classificationResult.detectedLanguage != "en" {
                skippedNonEnglish += 1
            } else if classificationResult.detectedLanguage == "en" {
                classifiedOK += 1
            }

            // Save every 25 entries
            if classifiedCount % 25 == 0 {
                try? context.save()
                logger.info("Classification progress: \(self.classifiedCount)/\(self.totalToClassify)")
            }
        }

        try? context.save()
        logger.info("Classification batch complete: \(classifiedOK) OK, \(skippedNonEnglish) non-English")

        isClassifying = false
        progress = ""
    }

    // MARK: - Private

    private func buildInstructions(from categories: [Category]) -> String {
        let categoryDescriptions = categories.map { cat in
            "- \(cat.label): \(cat.categoryDescription)"
        }.joined(separator: "\n")

        return """
            Categorize the following article into the user-defined categories listed below.
            Assign all categories that clearly match the article's content.
            When a specific category applies, also assign any broader category that encompasses it.
            Only assign a category when the article content provides clear evidence for it.

            Categories:
            \(categoryDescriptions)
            """
    }

}
