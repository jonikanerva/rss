import Foundation
import NaturalLanguage
import OSLog
import SwiftData

nonisolated func detectLanguage(_ text: String) -> String {
  let recognizer = NLLanguageRecognizer()
  recognizer.processString(text)
  return recognizer.dominantLanguage?.rawValue ?? "unknown"
}
nonisolated struct ProgressSnapshot: Sendable {
  let isClassifying: Bool
  let progress: String
  let classifiedCount: Int
  let totalToClassify: Int
  /// The batch-outcome cause, meaningful only when `ownsAbort` is true.
  let abort: ClassificationAbortReason?
  /// True only on a batch-outcome terminal. A mid-batch snapshot and the
  /// plain cancellation terminal never own the field, so they never set or
  /// overwrite a banner. A counting mid-batch snapshot clears a stale banner
  /// when a later batch reports committed progress.
  let ownsAbort: Bool

  init(
    isClassifying: Bool,
    progress: String,
    classifiedCount: Int,
    totalToClassify: Int,
    abort: ClassificationAbortReason? = nil,
    ownsAbort: Bool = false
  ) {
    self.isClassifying = isClassifying
    self.progress = progress
    self.classifiedCount = classifiedCount
    self.totalToClassify = totalToClassify
    self.abort = abort
    self.ownsAbort = ownsAbort
  }

  static let terminal = ProgressSnapshot(
    isClassifying: false, progress: "", classifiedCount: 0, totalToClassify: 0
  )

  /// Terminal snapshot that owns the batch outcome: `nil` records a clean
  /// attempt and clears a stale banner, non-nil records the abort cause.
  static func outcome(_ abort: ClassificationAbortReason?) -> ProgressSnapshot {
    ProgressSnapshot(
      isClassifying: false, progress: "", classifiedCount: 0, totalToClassify: 0,
      abort: abort, ownsAbort: true
    )
  }
}

@MainActor
@Observable
final class ClassificationEngine {
  private(set) var isClassifying = false
  private(set) var progress = ""
  private(set) var classifiedCount = 0
  private(set) var totalToClassify = 0
  private(set) var lastBatchClassifiedCount = 0
  private(set) var lastAbort: ClassificationAbortReason?
  private(set) var lastAbortProvider: ClassificationProviderKind?
  private(set) var batchProgressVersion = 0

  /// Every entry point routes work through this slot, so one runner is active
  /// at a time and no two runners send the same article to a provider.
  private var classificationTask: Task<ClassificationBatchOutcome, Never>?
  private var classificationTaskID: UUID?
  private var isContinuousModeActive = false
  private let providerFactoryOverride: (@Sendable () -> any ClassificationProvider)?
  private let sleep: @Sendable (Duration) async throws -> Void

  init(
    providerFactoryOverride: (@Sendable () -> any ClassificationProvider)? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.providerFactoryOverride = providerFactoryOverride
    self.sleep = sleep
  }

  func startContinuousClassification(writer: DataWriter) {
    isContinuousModeActive = true
    _ = replaceTask(writer: writer, operation: .continuous(nil))
  }

  func stopContinuousClassification() {
    classificationTask?.cancel()
    classificationTaskID = nil
    isContinuousModeActive = false
    apply(.terminal, provider: lastAbortProvider)
  }

  /// Call synchronously after a committed provider, model, or key change.
  func configurationChanged(writer: DataWriter) {
    classificationTask?.cancel()
    lastAbort = nil
    lastAbortProvider = nil
    apply(.terminal, provider: nil)
    startContinuousClassification(writer: writer)
  }

  func classifyUnclassified(writer: DataWriter) async {
    await runOneShot(writer: writer, reset: false)
  }

  func reclassifyAll(writer: DataWriter) async {
    await runOneShot(writer: writer, reset: true)
  }

  private func runOneShot(writer: DataWriter, reset: Bool) async {
    let (id, task) = replaceTask(writer: writer, operation: .once(reset: reset))
    let outcome = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard classificationTaskID == id else { return }
    classificationTaskID = nil
    if isContinuousModeActive, !Task.isCancelled {
      _ = replaceTask(writer: writer, operation: .continuous(outcome))
    }
  }

  private enum Operation: Sendable {
    case continuous(ClassificationBatchOutcome?)
    case once(reset: Bool)
  }

  private func replaceTask(
    writer: DataWriter, operation: Operation
  ) -> (UUID, Task<ClassificationBatchOutcome, Never>) {
    let previous = classificationTask
    previous?.cancel()
    let id = UUID()
    classificationTaskID = id
    let providerKind = ClassificationProviderKind.current
    let reporter: @Sendable (ProgressSnapshot) async -> Void = { snapshot in
      await MainActor.run {
        guard self.classificationTaskID == id else { return }
        self.apply(snapshot, provider: providerKind)
      }
    }
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: providerFactoryOverride ?? { Self.buildProvider() },
      reportProgress: reporter,
      sleep: sleep)
    // The engine owns this off-main task and waits for its predecessor before any work.
    let task = Task.detached(priority: .utility) {
      _ = await previous?.value
      guard !Task.isCancelled else { return ClassificationBatchOutcome.cancelled }
      switch operation {
      case .continuous(let initialOutcome):
        await runner.runContinuousLoop(initialOutcome: initialOutcome)
        return .cancelled
      case .once(let reset):
        let cutoff = articleCutoffDate()
        if reset { return await runner.runResetAndOneBatch(cutoffDate: cutoff) }
        return await runner.runOneBatch(cutoffDate: cutoff)
      }
    }
    classificationTask = task
    return (id, task)
  }

  #if DEBUG
    var isContinuousLoopActive: Bool { isContinuousModeActive }
    var currentClassificationTaskID: UUID? { classificationTaskID }
    private(set) var lastAbortWriteCount = 0
  #endif

  private func apply(_ snapshot: ProgressSnapshot, provider: ClassificationProviderKind?) {
    // Capture the count before the assignments below overwrite classifiedCount.
    if isClassifying && !snapshot.isClassifying {
      lastBatchClassifiedCount = classifiedCount
    }
    if !snapshot.isClassifying, snapshot.ownsAbort {
      // Write only on change: a same-value write re-announces the banner to
      // VoiceOver on every poll tick.
      if lastAbort != snapshot.abort {
        lastAbort = snapshot.abort
        #if DEBUG
          lastAbortWriteCount += 1
        #endif
      }
      lastAbortProvider = snapshot.abort == nil ? nil : provider
    }
    if snapshot.isClassifying, snapshot.classifiedCount > 0, lastAbort != nil {
      lastAbort = nil
      lastAbortProvider = nil
      #if DEBUG
        lastAbortWriteCount += 1
      #endif
    }
    if snapshot.isClassifying { batchProgressVersion &+= 1 }
    isClassifying = snapshot.isClassifying
    progress = snapshot.progress
    classifiedCount = snapshot.classifiedCount
    totalToClassify = snapshot.totalToClassify
  }

  func applyPreviewState(
    isClassifying: Bool = false, progress: String = "", classifiedCount: Int = 0,
    totalToClassify: Int = 0, lastAbort: ClassificationAbortReason? = nil,
    provider: ClassificationProviderKind? = nil
  ) {
    self.isClassifying = isClassifying
    self.progress = progress
    self.classifiedCount = classifiedCount
    self.totalToClassify = totalToClassify
    self.lastAbort = lastAbort
    self.lastAbortProvider = provider
  }

  /// Read the Keychain only inside a cloud-provider case, so an Apple
  /// Foundation Models user never triggers a Keychain read.
  nonisolated static func buildProvider(
    defaults: UserDefaults = .standard,
    keychainLoad: (String) -> String? = { KeychainHelper.load(key: $0) }
  ) -> any ClassificationProvider {
    switch ClassificationProviderKind.current(in: defaults) {
    case .openAI:
      guard let key = keychainLoad(KeychainHelper.openAIAPIKeychainKey), !key.isEmpty else {
        return AppleFMClassificationProvider()
      }
      return OpenAIClassificationProvider(apiKey: key, model: OpenAIModelSetting.current(in: defaults))
    case .vercel:
      return VercelClassificationProvider(apiKey: keychainLoad(KeychainHelper.vercelAPIKeychainKey) ?? "")
    case .appleFM:
      return AppleFMClassificationProvider()
    }
  }
}

nonisolated struct ClassificationRunner: Sendable {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "Classification")
  let writer: DataWriter
  let providerFactory: @Sendable () -> any ClassificationProvider
  let reportProgress: @Sendable (ProgressSnapshot) async -> Void
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

  func runContinuousLoop(initialOutcome: ClassificationBatchOutcome? = nil) async {
    var retryState = ClassificationRetryState()
    var outcome = initialOutcome
    while !Task.isCancelled {
      if let previous = outcome {
        guard let delay = retryState.delay(after: previous) else { return }
        do { try await sleep(delay) } catch { break }
      }
      guard !Task.isCancelled else { break }
      outcome = await runOneBatch(cutoffDate: articleCutoffDate())
    }
    await reportProgress(.terminal)
  }

  @discardableResult
  func runResetAndOneBatch(cutoffDate: Date) async -> ClassificationBatchOutcome {
    let provider = providerFactory()
    do {
      let categories = try await writer.fetchCategoryDefinitions()
      try await provider.validate(categories: categories)
      guard await provider.isAvailable else {
        await reportProgress(.outcome(.providerUnavailable))
        return .aborted(.poll, completed: 0)
      }
      try Task.checkCancellation()
      try await writer.resetClassification()
      try Task.checkCancellation()
    } catch {
      return await abort(error, completed: 0)
    }
    return await runOneBatch(cutoffDate: cutoffDate, providerOverride: provider)
  }

  @discardableResult
  func runOneBatch(
    cutoffDate: Date, chunkSize: Int = 50, providerOverride: (any ClassificationProvider)? = nil
  ) async -> ClassificationBatchOutcome {
    guard !Task.isCancelled else { return .cancelled }
    guard let categories = try? await writer.fetchCategoryDefinitions(), !categories.isEmpty else {
      return .completed(0)
    }
    guard let firstChunk = try? await writer.fetchUnclassifiedInputs(cutoffDate: cutoffDate, limit: chunkSize),
      !firstChunk.isEmpty
    else {
      if !Task.isCancelled { await reportProgress(.outcome(nil)) }
      return .completed(0)
    }
    let provider = providerOverride ?? providerFactory()
    do {
      try await provider.validate(categories: categories)
      try Task.checkCancellation()
    } catch { return await abort(error, completed: 0) }
    guard await provider.isAvailable else {
      if !Task.isCancelled { await reportProgress(.outcome(.providerUnavailable)) }
      return .aborted(.poll, completed: 0)
    }
    let supportedLanguages = await provider.supportedLanguageCodes
    var remaining = (try? await writer.countUnclassifiedEntries(cutoffDate: cutoffDate)) ?? firstChunk.count
    var completed = 0
    // An entry whose write fails stays unclassified and returns in the next
    // chunk fetch. Skip attempted IDs so the drain ends and the next poll retries.
    var attemptedIDs = Set<Int>()
    var lastProgress = ContinuousClock.now
    await reportProgress(progressSnapshot(completed: 0, remaining: remaining, provider: provider.name))
    var chunk = firstChunk
    while !chunk.isEmpty, !Task.isCancelled {
      let pending = chunk.filter { !attemptedIDs.contains($0.entryID) }
      if pending.isEmpty { break }
      for input in pending {
        if Task.isCancelled { break }
        attemptedIDs.insert(input.entryID)
        let result: ClassificationResult
        if shouldSkipClassification(title: input.title, body: input.body) {
          result = ClassificationResult(entryID: input.entryID, categoryLabel: uncategorizedLabel, confidence: nil)
        } else {
          let language = detectLanguage("\(input.title) \(input.body.prefix(500))")
          if let supportedLanguages, !supportedLanguages.contains(language) {
            result = ClassificationResult(entryID: input.entryID, categoryLabel: uncategorizedLabel, confidence: nil)
          } else {
            do {
              let response = try await provider.classify(title: input.title, body: input.body, url: input.url, categories: categories)
              try Task.checkCancellation()
              result = try resolveClassification(response, input: input, categories: categories)
            } catch {
              if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                await reportProgress(.terminal)
                return .cancelled
              }
              if (error as? any ClassificationFailure)?.batchAbort != nil {
                Self.logger.error(
                  "Classification provider '\(provider.name)' aborted the batch after \(completed) entries: \(String(describing: error), privacy: .private)"
                )
                return await abort(error, completed: completed)
              }
              result = ClassificationResult(entryID: input.entryID, categoryLabel: uncategorizedLabel, confidence: nil)
            }
          }
        }
        do {
          try Task.checkCancellation()
          try await writer.applyClassification(entryID: result.entryID, result: result)
          try Task.checkCancellation()
        } catch {
          if Task.isCancelled || error is CancellationError {
            await reportProgress(.terminal)
            return .cancelled
          }
          continue
        }
        completed += 1
        remaining = max(0, remaining - 1)
        let now = ContinuousClock.now
        // Report at most once per 200 ms: every report hops to MainActor.
        if now - lastProgress >= .milliseconds(200) {
          await reportProgress(progressSnapshot(completed: completed, remaining: remaining, provider: provider.name))
          lastProgress = now
        }
      }
      guard !Task.isCancelled else { break }
      chunk = (try? await writer.fetchUnclassifiedInputs(cutoffDate: cutoffDate, limit: chunkSize)) ?? []
      // Count pending entries only at a chunk boundary, never per entry: each
      // count is a SQLite query on the writer actor (STACK.md § 4).
      remaining = (try? await writer.countUnclassifiedEntries(cutoffDate: cutoffDate)) ?? chunk.count
    }
    if Task.isCancelled {
      await reportProgress(.terminal)
      return .cancelled
    }
    await reportProgress(progressSnapshot(completed: completed, remaining: remaining, provider: provider.name))
    await reportProgress(.outcome(nil))
    return .completed(completed)
  }

  private func progressSnapshot(completed: Int, remaining: Int, provider: String) -> ProgressSnapshot {
    ProgressSnapshot(
      isClassifying: true, progress: "Categorizing \(completed)/\(completed + remaining) (\(provider))", classifiedCount: completed,
      totalToClassify: completed + remaining)
  }

  private func abort(_ error: any Error, completed: Int) async -> ClassificationBatchOutcome {
    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
      await reportProgress(.terminal)
      return .cancelled
    }
    let failure = error as? any ClassificationFailure
    if completed > 0 {
      await reportProgress(
        ProgressSnapshot(
          isClassifying: true, progress: "Categorized \(completed) articles",
          classifiedCount: completed, totalToClassify: completed))
    }
    await reportProgress(.outcome(failure?.batchAbort ?? .providerUnavailable))
    return .aborted(failure?.retryDisposition ?? .poll, completed: completed)
  }
}

nonisolated func resolveClassification(
  _ result: ProviderClassificationResult, input: ClassificationInput, categories: [CategoryDefinition]
) throws -> ClassificationResult {
  let validLabels = Set(categories.map(\.label))
  switch result {
  case .choice(let category):
    guard validLabels.contains(category) || category == uncategorizedLabel else {
      throw VercelClassificationError.invalidResponse
    }
    return ClassificationResult(entryID: input.entryID, categoryLabel: category, confidence: nil)
  case .generative(let category, let confidence):
    let label = validLabels.contains(category) ? category : uncategorizedLabel
    let gatedLabel = applyConfidenceGate(
      label: label, llmConfidence: confidence,
      keywordScores: keywordMatchConfidence(title: input.title, body: input.body, categories: categories))
    return ClassificationResult(entryID: input.entryID, categoryLabel: gatedLabel, confidence: confidence)
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

/// Apply the confidence gate. A strong keyword match overrides an
/// uncategorized result; a real category below the threshold falls back to
/// uncategorized.
nonisolated func applyConfidenceGate(
  label: String,
  llmConfidence: Double,
  keywordScores: [String: Double]
) -> String {
  // An uncategorized result can be overridden by keywords.
  if label == uncategorizedLabel {
    let bestKeyword = keywordScores.max(by: { $0.value < $1.value })
    if let best = bestKeyword, best.value >= keywordOverrideThreshold {
      return best.key
    }
    return label
  }

  // A real category passes only above the confidence threshold.
  let keywordScore = keywordScores[label] ?? 0.0
  let finalConfidence = max(llmConfidence, keywordScore)
  if finalConfidence < confidenceThreshold {
    return uncategorizedLabel
  }
  return label
}

/// Compute keyword match confidence per category; a title match weighs more
/// than a body match. Returns category label → confidence in 0.0...1.0 for
/// every category with a match.
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
