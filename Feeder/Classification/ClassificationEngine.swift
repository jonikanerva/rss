import Foundation
import NaturalLanguage
import OSLog
import SwiftData

nonisolated private let logger = Logger(subsystem: "com.feeder.app", category: "Classification")

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

// MARK: - Progress snapshot (crosses actor boundary)

/// Snapshot of classification progress, sent from the background runner to MainActor for UI update.
nonisolated struct ProgressSnapshot: Sendable {
  let isClassifying: Bool
  let progress: String
  let classifiedCount: Int
  let totalToClassify: Int

  static let terminal = ProgressSnapshot(
    isClassifying: false, progress: "", classifiedCount: 0, totalToClassify: 0
  )
}

// MARK: - Classification Engine

/// Classifies articles using a pluggable ClassificationProvider.
/// Stays @MainActor @Observable for progress UI only — all classification work runs in a
/// detached `.utility` Task via ClassificationRunner so MainActor cannot be blocked.
@MainActor
@Observable
final class ClassificationEngine {
  private(set) var isClassifying = false
  private(set) var progress: String = ""
  private(set) var classifiedCount = 0
  private(set) var totalToClassify = 0

  /// The single-slot task that owns whatever classification work is in flight.
  /// `startContinuousClassification`, `classifyUnclassified`, and `reclassifyAll`
  /// all route through this slot — so only ever one runner is active, and manual
  /// triggers cannot race with the polling loop to duplicate provider calls.
  private var classificationTask: Task<Void, Never>?
  /// Unique ID per stored task, used to safely clear the slot from an awaiting
  /// one-shot entry point without clobbering a newer task that may have
  /// replaced it while we were awaiting. `Task` is a value type so `===`
  /// isn't available.
  private var classificationTaskID: UUID?

  /// User-intent flag: true between `startContinuousClassification` and
  /// `stopContinuousClassification`. `reclassifyAll` uses it to decide whether
  /// to restart the polling loop after the reset+batch completes.
  private var isContinuousModeActive = false

  // MARK: - Continuous classification (polling loop)

  func startContinuousClassification(writer: DataWriter) {
    classificationTask?.cancel()
    isContinuousModeActive = true
    let runner = makeRunner(writer: writer)
    let id = UUID()
    classificationTaskID = id
    classificationTask = Task.detached(priority: .utility) {
      await runner.runContinuousLoop()
    }
  }

  func stopContinuousClassification() {
    classificationTask?.cancel()
    classificationTask = nil
    classificationTaskID = nil
    isContinuousModeActive = false
  }

  // MARK: - One-shot classification

  /// Manual trigger for classifying unclassified entries. If the continuous
  /// polling loop is already running it handles unclassified entries within
  /// 2 s, so this no-ops to avoid spawning a second runner that would race
  /// the polling loop and duplicate provider calls.
  func classifyUnclassified(writer: DataWriter) async {
    if isContinuousModeActive { return }
    let runner = makeRunner(writer: writer)
    let cutoff = articleCutoffDate()
    let id = UUID()
    let task = Task.detached(priority: .utility) {
      await runner.runOneBatch(cutoffDate: cutoff)
    }
    classificationTask = task
    classificationTaskID = id
    await task.value
    // Only clear the slot if no newer task has replaced ours (see `classificationTaskID` doc).
    if classificationTaskID == id {
      classificationTask = nil
      classificationTaskID = nil
    }
  }

  /// Destructive one-shot: cancels the polling loop (if running), resets all
  /// classifications, re-classifies from scratch, then restarts the polling
  /// loop if it was previously active. Exclusive by construction.
  func reclassifyAll(writer: DataWriter) async {
    let shouldRestartContinuous = isContinuousModeActive
    classificationTask?.cancel()
    await classificationTask?.value
    classificationTask = nil
    classificationTaskID = nil
    isContinuousModeActive = false

    let runner = makeRunner(writer: writer)
    let cutoff = articleCutoffDate()
    let id = UUID()
    let task = Task.detached(priority: .utility) {
      await runner.runResetAndOneBatch(cutoffDate: cutoff)
    }
    classificationTask = task
    classificationTaskID = id
    await task.value
    if classificationTaskID == id {
      classificationTask = nil
      classificationTaskID = nil
    }

    if shouldRestartContinuous {
      startContinuousClassification(writer: writer)
    }
  }

  // MARK: - MainActor sink for progress snapshots

  private func apply(_ snapshot: ProgressSnapshot) {
    isClassifying = snapshot.isClassifying
    progress = snapshot.progress
    classifiedCount = snapshot.classifiedCount
    totalToClassify = snapshot.totalToClassify
  }

  // MARK: - Runner factory

  /// Build a runner. Captures `self` strongly for the progress reporter — the runner is owned
  /// by the detached Task whose lifetime is bounded by `classificationTask?.cancel()` on stop,
  /// so no retain cycle. CLAUDE.md prohibits `[weak self]` in Task closures.
  private func makeRunner(writer: DataWriter) -> ClassificationRunner {
    let reporter: @Sendable (ProgressSnapshot) async -> Void = { snapshot in
      await MainActor.run { self.apply(snapshot) }
    }
    // Provider is built per-batch via this Sendable factory, so a Settings change
    // (provider switch / OpenAI key entry) takes effect on the next polling cycle
    // without requiring `stopContinuousClassification` + `start` round-trip.
    let providerFactory: @Sendable () -> any ClassificationProvider = { Self.buildProvider() }
    return ClassificationRunner(
      writer: writer, providerFactory: providerFactory, reportProgress: reporter
    )
  }

  // MARK: - Provider factory

  /// Resolve the configured classification provider from UserDefaults + Keychain.
  /// Static + nonisolated so it can be invoked from background tasks per batch.
  nonisolated static func buildProvider() -> any ClassificationProvider {
    let selection = UserDefaults.standard.string(forKey: "classification_provider") ?? "apple_fm"
    switch selection {
    case "openai":
      let apiKey = KeychainHelper.load(key: "openai_api_key") ?? ""
      return OpenAIClassificationProvider(apiKey: apiKey)
    default:
      return AppleFMClassificationProvider()
    }
  }
}

// MARK: - Classification Runner (nonisolated, runs on background task)

/// Executes the classification loop entirely off MainActor. Created per run by the engine and
/// driven from a `.utility` priority detached Task. Reports progress back to MainActor via the
/// Sendable `reportProgress` closure, throttled to once per 200ms.
nonisolated struct ClassificationRunner: Sendable {
  let writer: DataWriter
  /// Resolved per batch so a provider/key change in Settings takes effect without restart.
  let providerFactory: @Sendable () -> any ClassificationProvider
  let reportProgress: @Sendable (ProgressSnapshot) async -> Void

  func runContinuousLoop() async {
    while !Task.isCancelled {
      let cutoff = articleCutoffDate()
      await runOneBatch(cutoffDate: cutoff)
      if Task.isCancelled { break }
      try? await Task.sleep(for: .seconds(2))
    }
    await reportProgress(.terminal)
  }

  func runResetAndOneBatch(cutoffDate: Date) async {
    try? await writer.resetClassification()
    await runOneBatch(cutoffDate: cutoffDate)
  }

  func runOneBatch(cutoffDate: Date) async {
    guard let categories = try? await writer.fetchCategoryDefinitions(),
      !categories.isEmpty
    else { return }

    guard let inputs = try? await writer.fetchUnclassifiedInputs(cutoffDate: cutoffDate),
      !inputs.isEmpty
    else {
      await reportProgress(.terminal)
      return
    }

    let provider = providerFactory()
    guard await provider.isAvailable else {
      logger.error("Classification provider '\(provider.name)' not available")
      // Symmetry with the no-inputs early return: clear any leftover spinner state.
      await reportProgress(.terminal)
      return
    }

    let totalToClassify = inputs.count
    let providerName = provider.name
    logger.info(
      "Classifying \(inputs.count) entries with \(categories.count) categories using \(providerName)"
    )

    let instructions = buildClassificationInstructions(from: categories)
    let validLabels = Set(categories.map(\.label))
    let supportedLangCodes = await provider.supportedLanguageCodes

    var processedCount = 0
    var lastProgressUpdate: ContinuousClock.Instant = .now
    await reportProgress(
      ProgressSnapshot(
        isClassifying: true,
        progress: "Categorizing 0/\(totalToClassify) (\(providerName))",
        classifiedCount: 0,
        totalToClassify: totalToClassify
      )
    )

    for input in inputs {
      if Task.isCancelled { break }

      let result: ClassificationResult
      if shouldSkipClassification(title: input.title, body: input.body) {
        result = ClassificationResult(
          entryID: input.entryID,
          categoryLabel: uncategorizedLabel,
          storyKey: normalizeStoryKey(input.title),
          detectedLanguage: "unknown",
          confidence: 0.0
        )
      } else {
        let keywordScores = keywordMatchConfidence(
          title: input.title, body: input.body, categories: categories
        )
        let lang = detectLanguage("\(input.title) \(input.body.prefix(500))")

        if let langCodes = supportedLangCodes, !langCodes.contains(lang) {
          result = ClassificationResult(
            entryID: input.entryID,
            categoryLabel: uncategorizedLabel,
            storyKey: normalizeStoryKey(input.title),
            detectedLanguage: lang,
            confidence: 0.0
          )
        } else {
          do {
            let providerResult = try await provider.classify(
              title: input.title,
              body: input.body,
              url: input.url,
              instructions: instructions,
              validLabels: validLabels
            )
            let rawLabel =
              validLabels.contains(providerResult.category)
              ? providerResult.category : uncategorizedLabel
            let gatedLabel = applyConfidenceGate(
              label: rawLabel,
              llmConfidence: providerResult.confidence,
              keywordScores: keywordScores
            )
            for (kwCategory, kwScore) in keywordScores where kwScore >= 0.8 {
              if gatedLabel != kwCategory {
                logger.info(
                  "Keyword-LLM disagreement: keyword=\(kwCategory) (score=\(kwScore)), LLM chose \(gatedLabel)"
                )
              }
            }
            result = ClassificationResult(
              entryID: input.entryID,
              categoryLabel: gatedLabel,
              storyKey: normalizeStoryKey(providerResult.storyKey),
              detectedLanguage: lang,
              confidence: providerResult.confidence
            )
          } catch {
            result = ClassificationResult(
              entryID: input.entryID,
              categoryLabel: uncategorizedLabel,
              storyKey: normalizeStoryKey(input.title),
              detectedLanguage: lang,
              confidence: 0.0
            )
          }
        }
      }

      try? await writer.applyClassification(entryID: result.entryID, result: result)

      processedCount += 1
      let now = ContinuousClock.now
      if now - lastProgressUpdate >= .milliseconds(200) || processedCount == totalToClassify {
        await reportProgress(
          ProgressSnapshot(
            isClassifying: true,
            progress: "Categorizing \(processedCount)/\(totalToClassify) (\(providerName))",
            classifiedCount: processedCount,
            totalToClassify: totalToClassify
          )
        )
        lastProgressUpdate = now
      }
    }

    logger.info("Classification batch complete: \(processedCount) entries")
    await reportProgress(.terminal)
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
