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
@MainActor
@Observable
final class ClassificationEngine {
    private(set) var isClassifying = false
    private(set) var progress: String = ""
    private(set) var classifiedCount = 0
    private(set) var totalToClassify = 0

    /// Classify all unclassified entries in the database.
    func classifyUnclassified(in context: ModelContext) async {
        guard !isClassifying else { return }
        isClassifying = true
        progress = "Preparing..."

        do {
            // Fetch user-defined categories (fast, on main)
            var categoryDescriptor = FetchDescriptor<Category>()
            categoryDescriptor.sortBy = [SortDescriptor(\Category.sortOrder)]
            let categories = try context.fetch(categoryDescriptor)

            guard !categories.isEmpty else {
                progress = "No categories defined"
                isClassifying = false
                return
            }

            // Fetch unclassified entries (fast, on main)
            let entryDescriptor = FetchDescriptor<Entry>(
                predicate: #Predicate<Entry> { $0.storyKey == nil },
                sortBy: [SortDescriptor(\Entry.createdAt, order: .reverse)]
            )
            let entries = try context.fetch(entryDescriptor)

            guard !entries.isEmpty else {
                progress = "All entries classified"
                isClassifying = false
                return
            }

            totalToClassify = entries.count
            classifiedCount = 0
            logger.info("Classifying \(entries.count) entries with \(categories.count) categories")

            // Check model availability
            let model = SystemLanguageModel.default
            guard case .available = model.availability else {
                progress = "Apple Intelligence not available"
                logger.error("Apple Foundation Model not available")
                isClassifying = false
                return
            }

            // Prepare lightweight inputs (extract data from SwiftData objects on main)
            let inputs: [ClassificationInput] = entries.map { entry in
                ClassificationInput(
                    entryID: entry.feedbinEntryID,
                    title: entry.title ?? "Untitled",
                    summary: entry.summary ?? "",
                    body: entry.bestBody
                )
            }

            // Build lookup for applying results back
            let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.feedbinEntryID, $0) })

            let instructions = buildInstructions(from: categories)
            let validLabels = Set(categories.map { $0.label })

            // Process entries one at a time — FM inference is async and must happen
            // on main actor (SystemLanguageModel requires it), but we do the CPU-heavy
            // pre-processing (HTML strip, language detection) on a background thread.
            var skippedNonEnglish = 0
            var classifiedOK = 0
            var classificationErrors = 0

            for input in inputs {
                // CPU-heavy pre-processing on background thread
                let preprocessed = await Task.detached(priority: .utility) {
                    let textForDetection = "\(input.title) \(stripHTML(input.body).prefix(500))"
                    let lang = detectLanguage(textForDetection)
                    let strippedBody = stripHTML(input.body)
                    return (lang: lang, strippedBody: strippedBody, textForDetection: textForDetection)
                }.value

                classifiedCount += 1
                progress = "Classifying [\(classifiedCount)/\(totalToClassify)] \(input.title.prefix(40))..."

                guard let entry = entriesByID[input.entryID] else { continue }
                entry.detectedLanguage = preprocessed.lang

                if preprocessed.lang != "en" {
                    entry.categoryLabels = ["other"]
                    entry.storyKey = normalizeStoryKey(input.title)
                    skippedNonEnglish += 1
                    continue
                }

                // FM inference (async, Apple requires main actor for LanguageModelSession)
                do {
                    let result = try await classifyEntry(
                        input: input,
                        strippedBody: preprocessed.strippedBody,
                        model: model,
                        instructions: instructions,
                        validLabels: validLabels
                    )
                    entry.categoryLabels = result.categories
                    entry.storyKey = result.storyKey
                    classifiedOK += 1
                    logger.debug("Classified: \(input.title.prefix(60)) → \(result.categories)")
                } catch {
                    entry.categoryLabels = ["other"]
                    entry.storyKey = normalizeStoryKey(input.title)
                    classificationErrors += 1
                    logger.error("Classification error for \(input.title.prefix(60)): \(error.localizedDescription)")
                }

                // Save every 25 entries
                if classifiedCount % 25 == 0 {
                    try context.save()
                    logger.info("Classification progress: \(self.classifiedCount)/\(self.totalToClassify)")
                    // Yield to let UI process events
                    await Task.yield()
                }
            }

            try context.save()
            progress = "Classified \(entries.count) entries (\(classifiedOK) OK, \(skippedNonEnglish) non-English, \(classificationErrors) errors)"
            logger.info("Classification complete: \(entries.count) entries (\(classifiedOK) OK, \(skippedNonEnglish) non-English, \(classificationErrors) errors)")
        } catch {
            progress = "Error: \(error.localizedDescription)"
            logger.error("Classification failed: \(error.localizedDescription)")
        }

        isClassifying = false
    }

    /// Reclassify all entries (e.g., after category changes).
    func reclassifyAll(in context: ModelContext) async {
        let descriptor = FetchDescriptor<Entry>()
        if let entries = try? context.fetch(descriptor) {
            for entry in entries {
                entry.categoryLabels = []
                entry.storyKey = nil
                entry.detectedLanguage = nil
            }
            try? context.save()
        }
        await classifyUnclassified(in: context)
    }

    // MARK: - Private

    private func classifyEntry(
        input: ClassificationInput,
        strippedBody: String,
        model: SystemLanguageModel,
        instructions: String,
        validLabels: Set<String>
    ) async throws -> (categories: [String], storyKey: String) {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let prompt = buildPrompt(title: input.title, summary: input.summary, strippedBody: strippedBody)
        let options = GenerationOptions(sampling: .greedy)

        let response = try await session.respond(
            to: prompt,
            generating: ArticleClassification.self,
            options: options
        )

        let classification = response.content

        var validatedLabels = classification.categories.filter { validLabels.contains($0) }
        if validatedLabels.isEmpty {
            validatedLabels = ["other"]
        }

        let storyKey = normalizeStoryKey(classification.storyKey)
        return (categories: validatedLabels, storyKey: storyKey)
    }

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

    private func buildPrompt(title: String, summary: String, strippedBody: String) -> String {
        var body = strippedBody
        let maxBodyChars = 2000
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars)) + "..."
        }

        return """
            title: \(title)
            summary: \(summary)
            body: \(body)
            """
    }
}
