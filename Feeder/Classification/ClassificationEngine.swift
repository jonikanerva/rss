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
            // Fetch user-defined categories
            var categoryDescriptor = FetchDescriptor<Category>()
            categoryDescriptor.sortBy = [SortDescriptor(\Category.sortOrder)]
            let categories = try context.fetch(categoryDescriptor)

            guard !categories.isEmpty else {
                progress = "No categories defined"
                isClassifying = false
                return
            }

            // Fetch unclassified entries (those with no storyKey — storyKey is set during classification)
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

            // Build classification instructions from user's categories
            let instructions = buildInstructions(from: categories)
            let validLabels = Set(categories.map { $0.label })

            // Classify each entry
            var skippedNonEnglish = 0
            var classifiedOK = 0
            var classificationErrors = 0

            for entry in entries {
                // Yield to let UI stay responsive
                await Task.yield()

                classifiedCount += 1
                let title = entry.title ?? "Untitled"
                progress = "Classifying [\(classifiedCount)/\(totalToClassify)] \(title.prefix(40))..."

                // Language detection: skip non-English
                let textForDetection = "\(title) \(stripHTML(entry.bestBody).prefix(500))"
                let detectedLang = detectLanguage(textForDetection)
                entry.detectedLanguage = detectedLang

                if detectedLang != "en" {
                    entry.categoryLabels = ["other"]
                    entry.storyKey = normalizeStoryKey(title)
                    skippedNonEnglish += 1
                    logger.debug("Skipped non-English (\(detectedLang)): \(title.prefix(60))")
                    continue
                }

                // Classify with Apple FM
                do {
                    let result = try await classifyEntry(
                        entry,
                        model: model,
                        instructions: instructions,
                        validLabels: validLabels
                    )
                    entry.categoryLabels = result.categories
                    entry.storyKey = result.storyKey
                    classifiedOK += 1
                    logger.debug("Classified: \(title.prefix(60)) → \(result.categories)")
                } catch {
                    entry.categoryLabels = ["other"]
                    entry.storyKey = normalizeStoryKey(title)
                    classificationErrors += 1
                    logger.error("Classification error for \(title.prefix(60)): \(error.localizedDescription)")
                }

                // Save and log every 25 entries
                if classifiedCount % 25 == 0 {
                    try context.save()
                    logger.info("Classification progress: \(self.classifiedCount)/\(self.totalToClassify) (\(classifiedOK) OK, \(skippedNonEnglish) non-English, \(classificationErrors) errors)")
                }
            }

            // Final save
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
        // Clear all classification data
        let descriptor = FetchDescriptor<Entry>()
        if let entries = try? context.fetch(descriptor) {
            for entry in entries {
                entry.categoryLabels = []
                entry.storyKey = nil
                entry.detectedLanguage = nil
            }
            try? context.save()
        }
        // Re-run classification
        await classifyUnclassified(in: context)
    }

    // MARK: - Private

    private func classifyEntry(
        _ entry: Entry,
        model: SystemLanguageModel,
        instructions: String,
        validLabels: Set<String>
    ) async throws -> (categories: [String], storyKey: String) {
        let session = LanguageModelSession(model: model, instructions: instructions)
        let prompt = buildPrompt(for: entry)
        let options = GenerationOptions(sampling: .greedy)

        let response = try await session.respond(
            to: prompt,
            generating: ArticleClassification.self,
            options: options
        )

        let classification = response.content

        // Validate labels against user-defined categories
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

    private func buildPrompt(for entry: Entry) -> String {
        var body = stripHTML(entry.bestBody)
        // Apple Foundation Models have a small context window — keep prompt compact
        let maxBodyChars = 2000
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars)) + "..."
        }

        return """
            title: \(entry.title ?? "Untitled")
            summary: \(entry.summary ?? "")
            body: \(body)
            """
    }

    private func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        // Remove HTML tags
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue ?? "unknown"
    }

    private func normalizeStoryKey(_ value: String) -> String {
        let lowered = value.lowercased()
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "story-unknown" : String(trimmed.prefix(80))
    }
}
