import Foundation
import FoundationModels
import NaturalLanguage
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

// MARK: - Generable output type

@Generable
struct ArticleClassification {
  @Guide(
    description:
      "The most specific matching category labels from the provided list. Assign the deepest matching subcategory, not its parent.",
    .count(1...4))
  var categories: [String]

  @Guide(description: "A short stable kebab-case topic key for story grouping, e.g. 'apple-m5-macbook-pro' or 'openai-dod-contract'")
  var storyKey: String

  @Guide(description: "How confident you are in the classification, from 0.0 (guessing) to 1.0 (certain)")
  var confidence: Double
}

// MARK: - Pure helper functions (nonisolated)

nonisolated func detectLanguage(_ text: String) -> String {
  let recognizer = NLLanguageRecognizer()
  recognizer.processString(text)
  return recognizer.dominantLanguage?.rawValue ?? "unknown"
}

nonisolated func normalizeStoryKey(_ value: String) -> String {
  let lowered = value.lowercased()
  let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
  let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  return trimmed.isEmpty ? "story-unknown" : String(trimmed.prefix(80))
}

// MARK: - Classification Engine

/// Classifies articles using Apple Foundation Models.
/// Stays @MainActor @Observable for progress UI only — all SwiftData operations via DataWriter.
@MainActor
@Observable
final class ClassificationEngine {
  private(set) var isClassifying = false
  private(set) var progress: String = ""
  private(set) var classifiedCount = 0
  private(set) var totalToClassify = 0

  private var classificationTask: Task<Void, Never>?

  // MARK: - Continuous classification (polling loop)

  func startContinuousClassification(writer: DataWriter) {
    classificationTask?.cancel()
    classificationTask = Task {
      while !Task.isCancelled {
        await classifyNextBatch(writer: writer)
        if Task.isCancelled { break }
        try? await Task.sleep(for: .seconds(2))
      }
      isClassifying = false
      progress = ""
    }
  }

  func stopContinuousClassification() {
    classificationTask?.cancel()
    classificationTask = nil
  }

  // MARK: - One-shot classification

  func classifyUnclassified(writer: DataWriter) async {
    await classifyNextBatch(writer: writer)
  }

  func reclassifyAll(writer: DataWriter) async {
    try? await writer.resetClassification()
    await classifyNextBatch(writer: writer)
  }

  // MARK: - Core classification logic

  private func classifyNextBatch(writer: DataWriter) async {
    // Fetch data from background actor — zero MainActor SwiftData work
    guard let categories = try? await writer.fetchCategoryDefinitions(),
      !categories.isEmpty
    else { return }

    guard let inputs = try? await writer.fetchUnclassifiedInputs(),
      !inputs.isEmpty
    else {
      if isClassifying {
        isClassifying = false
        progress = ""
      }
      return
    }

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
      logger.error("Apple Foundation Model not available")
      return
    }

    isClassifying = true
    totalToClassify = inputs.count
    classifiedCount = 0
    logger.info("Classifying \(inputs.count) entries with \(categories.count) categories")

    let instructions = buildInstructions(from: categories)
    let validLabels = Set(categories.map(\.label))
    let supportedLangCodes = Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })

    // Conservative context budget: ~3800 tokens to leave room for output and schema overhead
    let maxContextChars = 3800 * 4

    for input in inputs {
      if Task.isCancelled { break }

      // Skip completely empty articles (no title AND no body)
      if shouldSkipClassification(title: input.title, body: input.body) {
        let emptyResult = ClassificationResult(
          entryID: input.entryID,
          categoryLabels: [uncategorizedLabel],
          storyKey: normalizeStoryKey(input.title),
          detectedLanguage: "unknown",
          confidence: 0.0
        )
        try? await writer.applyClassification(entryID: emptyResult.entryID, result: emptyResult)
        classifiedCount += 1
        progress = "Categorizing \(classifiedCount)/\(totalToClassify)"
        continue
      }

      // Compute keyword match before LLM (cheap, deterministic)
      let keywordScores = keywordMatchConfidence(title: input.title, body: input.body, categories: categories)

      // All heavy work on background thread
      let result = await Task.detached(priority: .utility) {
        let lang = detectLanguage("\(input.title) \(input.body.prefix(500))")

        // Skip languages not supported by the on-device model to avoid
        // session prewarm warnings and wasted inference attempts.
        guard supportedLangCodes.contains(lang) else {
          return ClassificationResult(
            entryID: input.entryID,
            categoryLabels: [uncategorizedLabel],
            storyKey: normalizeStoryKey(input.title),
            detectedLanguage: lang,
            confidence: 0.0
          )
        }

        do {
          let session = LanguageModelSession(model: model, instructions: instructions)

          let promptPrefix = "title: \(input.title)\ncontent: "
          let usedChars = instructions.count + promptPrefix.count
          let maxBodyChars = max(500, maxContextChars - usedChars)
          let body = String(input.body.prefix(maxBodyChars))
          let prompt = promptPrefix + body
          let options = GenerationOptions(sampling: .greedy)
          let response = try await session.respond(
            to: prompt,
            generating: ArticleClassification.self,
            options: options
          )
          let classification = response.content
          let rawLabels = filterValidLabels(classification.categories, validSet: validLabels)

          // Apply confidence gate: combine LLM confidence with keyword scores
          let gatedLabels = applyConfidenceGate(
            labels: rawLabels,
            llmConfidence: classification.confidence,
            keywordScores: keywordScores
          )

          return ClassificationResult(
            entryID: input.entryID,
            categoryLabels: gatedLabels,
            storyKey: normalizeStoryKey(classification.storyKey),
            detectedLanguage: lang,
            confidence: classification.confidence
          )
        } catch {
          return ClassificationResult(
            entryID: input.entryID,
            categoryLabels: [uncategorizedLabel],
            storyKey: normalizeStoryKey(input.title),
            detectedLanguage: lang,
            confidence: 0.0
          )
        }
      }.value

      // Log keyword/LLM disagreements for diagnostics (MainActor context)
      for (kwCategory, kwScore) in keywordScores where kwScore >= 0.8 {
        if !result.categoryLabels.contains(kwCategory) {
          logger.info("Keyword-LLM disagreement: keyword=\(kwCategory) (score=\(kwScore)), LLM chose \(result.categoryLabels)")
        }
      }

      // Write result via background actor — zero MainActor SwiftData work
      try? await writer.applyClassification(entryID: result.entryID, result: result)

      // Only progress UI state on MainActor (microseconds)
      classifiedCount += 1
      progress = "Categorizing \(classifiedCount)/\(totalToClassify)"
    }

    let finalCount = classifiedCount
    logger.info("Classification batch complete: \(finalCount) entries")
    isClassifying = false
    progress = ""
  }

  // MARK: - Private

  private nonisolated func buildInstructions(from categories: [CategoryDefinition]) -> String {
    buildClassificationInstructions(from: categories)
  }
}

// MARK: - Pure classification helpers (nonisolated, testable)

/// Build LLM system instructions from category definitions.
nonisolated func buildClassificationInstructions(from categories: [CategoryDefinition]) -> String {
  let topLevel = categories.filter { $0.isTopLevel }
  let children = categories.filter { !$0.isTopLevel }

  var lines: [String] = []
  for parent in topLevel {
    lines.append("- \(parent.label): \(parent.description)")
    for child in children where child.parentLabel == parent.label {
      lines.append("  - \(child.label): \(child.description)")
    }
  }
  lines.append("- \(uncategorizedLabel): Use only when no other category clearly matches. Never combine with another category.")
  let categoryDescriptions = lines.joined(separator: "\n")

  return """
    Categorize the article into the most specific matching categories below. \
    Assign subcategories over parents when both match. \
    Only assign categories with clear evidence in the article. \
    Prefer fewer categories — assign 1 unless multiple clearly apply. \
    If the article content is too short, vague, or does not clearly match any category, assign only "uncategorized".

    Categories:
    \(categoryDescriptions)
    """
}

/// Filter labels to only valid category labels. Defaults to [uncategorizedLabel] if none valid.
nonisolated func filterValidLabels(_ labels: [String], validSet: Set<String>) -> [String] {
  let filtered = labels.filter { validSet.contains($0) }
  return filtered.isEmpty ? [uncategorizedLabel] : filtered
}

/// Returns true when an article has no meaningful content to classify.
nonisolated func shouldSkipClassification(title: String, body: String) -> Bool {
  title == "Untitled" && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Minimum confidence threshold for accepting a classification. Below this, assign "Uncategorized".
nonisolated let confidenceThreshold = 0.5

/// Apply confidence gate: if the combined confidence (max of LLM and keyword) is below threshold,
/// override labels to uncategorized.
nonisolated func applyConfidenceGate(
  labels: [String],
  llmConfidence: Double,
  keywordScores: [String: Double]
) -> [String] {
  let bestKeywordScore = labels.compactMap { keywordScores[$0] }.max() ?? 0.0
  let finalConfidence = max(llmConfidence, bestKeywordScore)
  if finalConfidence < confidenceThreshold {
    return [uncategorizedLabel]
  }
  return labels
}

/// Compute keyword match confidence per category. Title matches weigh more than body matches.
/// Returns a dictionary of categoryLabel → confidence (0.0–1.0) for categories with any match.
nonisolated func keywordMatchConfidence(
  title: String,
  body: String,
  categories: [CategoryDefinition]
) -> [String: Double] {
  let titleLower = title.lowercased()
  let bodyLower = body.lowercased()
  var result: [String: Double] = [:]

  for category in categories where !category.keywords.isEmpty {
    var score = 0.0
    for keyword in category.keywords {
      let keywordLower = keyword.lowercased()
      let titleHit = titleLower.contains(keywordLower)
      let bodyHit = bodyLower.contains(keywordLower)
      if titleHit {
        score += 0.8
      } else if bodyHit {
        score += 0.4
      }
    }
    if score > 0 {
      result[category.label] = min(score, 1.0)
    }
  }
  return result
}
