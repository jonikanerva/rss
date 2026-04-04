import Foundation
import NaturalLanguage
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

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

/// Classifies articles using a pluggable ClassificationProvider.
/// Stays @MainActor @Observable for progress UI only — all SwiftData operations via DataWriter.
@MainActor
@Observable
final class ClassificationEngine {
  private(set) var isClassifying = false
  private(set) var progress: String = ""
  private(set) var classifiedCount = 0
  private(set) var totalToClassify = 0

  private var classificationTask: Task<Void, Never>?
  private var lastProgressUpdate: ContinuousClock.Instant = .now

  // MARK: - Continuous classification (polling loop)

  func startContinuousClassification(writer: DataWriter) {
    classificationTask?.cancel()
    classificationTask = Task {
      while !Task.isCancelled {
        let cutoff = articleCutoffDate()
        await classifyNextBatch(writer: writer, cutoffDate: cutoff)
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
    let cutoff = articleCutoffDate()
    await classifyNextBatch(writer: writer, cutoffDate: cutoff)
  }

  func reclassifyAll(writer: DataWriter) async {
    try? await writer.resetClassification()
    let cutoff = articleCutoffDate()
    await classifyNextBatch(writer: writer, cutoffDate: cutoff)
  }

  // MARK: - Provider factory

  private func makeProvider() -> any ClassificationProvider {
    let selection = UserDefaults.standard.string(forKey: "classification_provider") ?? "apple_fm"
    switch selection {
    case "openai":
      let apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
      return OpenAIClassificationProvider(apiKey: apiKey)
    default:
      return AppleFMClassificationProvider()
    }
  }

  // MARK: - Core classification logic

  private func classifyNextBatch(writer: DataWriter, cutoffDate: Date) async {
    // Fetch data from background actor — zero MainActor SwiftData work
    guard let categories = try? await writer.fetchCategoryDefinitions(),
      !categories.isEmpty
    else { return }

    guard let inputs = try? await writer.fetchUnclassifiedInputs(cutoffDate: cutoffDate),
      !inputs.isEmpty
    else {
      if isClassifying {
        isClassifying = false
        progress = ""
      }
      return
    }

    let provider = makeProvider()
    guard await provider.isAvailable else {
      logger.error("Classification provider '\(provider.name)' not available")
      return
    }

    isClassifying = true
    totalToClassify = inputs.count
    classifiedCount = 0
    let providerName = provider.name
    logger.info("Classifying \(inputs.count) entries with \(categories.count) categories using \(providerName)")

    let instructions = buildInstructions(from: categories)
    let validLabels = Set(categories.map(\.label))

    let supportedLangCodes = await provider.supportedLanguageCodes

    var processedCount = 0

    for input in inputs {
      if Task.isCancelled { break }

      // Skip completely empty articles (no title AND no body)
      if shouldSkipClassification(title: input.title, body: input.body) {
        let emptyResult = ClassificationResult(
          entryID: input.entryID,
          categoryLabel: uncategorizedLabel,
          storyKey: normalizeStoryKey(input.title),
          detectedLanguage: "unknown",
          confidence: 0.0
        )
        try? await writer.applyClassification(entryID: emptyResult.entryID, result: emptyResult)
        processedCount += 1
        let now = ContinuousClock.now
        if now - lastProgressUpdate >= .milliseconds(200) || processedCount == inputs.count {
          classifiedCount = processedCount
          progress = "Categorizing \(processedCount)/\(totalToClassify) (\(providerName))"
          lastProgressUpdate = now
        }
        continue
      }

      // Compute keyword match before LLM (cheap, deterministic)
      let keywordScores = keywordMatchConfidence(
        title: input.title, body: input.body, categories: categories)

      // All heavy work on background thread — provider and langCodes are Sendable
      let result = await Task.detached(priority: .utility) { [provider, supportedLangCodes] in
        let lang = detectLanguage("\(input.title) \(input.body.prefix(500))")

        // Skip languages not supported by the provider
        if let langCodes = supportedLangCodes, !langCodes.contains(lang) {
          return ClassificationResult(
            entryID: input.entryID,
            categoryLabel: uncategorizedLabel,
            storyKey: normalizeStoryKey(input.title),
            detectedLanguage: lang,
            confidence: 0.0
          )
        }

        do {
          let providerResult = try await provider.classify(
            title: input.title,
            body: input.body,
            instructions: instructions,
            validLabels: validLabels
          )
          let rawLabel =
            validLabels.contains(providerResult.category)
            ? providerResult.category : uncategorizedLabel

          // Apply confidence gate: combine LLM confidence with keyword scores
          let gatedLabel = applyConfidenceGate(
            label: rawLabel,
            llmConfidence: providerResult.confidence,
            keywordScores: keywordScores
          )

          return ClassificationResult(
            entryID: input.entryID,
            categoryLabel: gatedLabel,
            storyKey: normalizeStoryKey(providerResult.storyKey),
            detectedLanguage: lang,
            confidence: providerResult.confidence
          )
        } catch {
          return ClassificationResult(
            entryID: input.entryID,
            categoryLabel: uncategorizedLabel,
            storyKey: normalizeStoryKey(input.title),
            detectedLanguage: lang,
            confidence: 0.0
          )
        }
      }.value

      // Log keyword/LLM disagreements for diagnostics (MainActor context)
      for (kwCategory, kwScore) in keywordScores where kwScore >= 0.8 {
        if result.categoryLabel != kwCategory {
          logger.info(
            "Keyword-LLM disagreement: keyword=\(kwCategory) (score=\(kwScore)), LLM chose \(result.categoryLabel)"
          )
        }
      }

      // Write result via background actor — zero MainActor SwiftData work
      try? await writer.applyClassification(entryID: result.entryID, result: result)

      // Throttled progress UI update (at most once per 200ms)
      processedCount += 1
      let now = ContinuousClock.now
      if now - lastProgressUpdate >= .milliseconds(200) || processedCount == inputs.count {
        classifiedCount = processedCount
        progress = "Categorizing \(processedCount)/\(totalToClassify) (\(providerName))"
        lastProgressUpdate = now
      }
    }

    // Ensure final count is published
    classifiedCount = processedCount
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
  var lines: [String] = []
  for category in categories {
    lines.append("- \(category.label): \(category.description)")
  }
  lines.append(
    "- \(uncategorizedLabel): Use only when no other category clearly matches."
  )
  let categoryDescriptions = lines.joined(separator: "\n")

  return """
    Assign the single best matching category to this article. \
    Choose exactly one category — the most specific match with clear evidence. \
    Only use uncategorized when no other category fits.

    Categories:
    \(categoryDescriptions)
    """
}

/// Returns true when an article has no meaningful content to classify.
nonisolated func shouldSkipClassification(title: String, body: String) -> Bool {
  title == "Untitled" && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Minimum confidence threshold for accepting a classification. Below this, assign "Uncategorized".
nonisolated let confidenceThreshold = 0.3

/// Minimum keyword confidence to override an LLM "uncategorized" result.
nonisolated let keywordOverrideThreshold = 0.8

/// Apply confidence gate: if LLM chose uncategorized and keywords have a strong match, use keywords.
/// If LLM chose a real category but confidence is too low, fall back to uncategorized.
nonisolated func applyConfidenceGate(
  label: String,
  llmConfidence: Double,
  keywordScores: [String: Double]
) -> String {
  // If LLM chose uncategorized, check if keywords can override
  if label == uncategorizedLabel {
    let bestKeyword = keywordScores.max(by: { $0.value < $1.value })
    if let best = bestKeyword, best.value >= keywordOverrideThreshold {
      return best.key
    }
    return label
  }

  // LLM chose a real category — apply confidence threshold
  let keywordScore = keywordScores[label] ?? 0.0
  let finalConfidence = max(llmConfidence, keywordScore)
  if finalConfidence < confidenceThreshold {
    return uncategorizedLabel
  }
  return label
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
