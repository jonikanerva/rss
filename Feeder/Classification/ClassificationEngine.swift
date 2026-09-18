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

// MARK: - Progress snapshot (crosses actor boundary)

/// Snapshot of classification progress, sent from the background runner to MainActor for UI update.
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
  /// through the evidence-of-progress rule in `ClassificationEngine.apply(_:)`.
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

// MARK: - Classification Engine

/// Classifies articles through a pluggable `ClassificationProvider`. It is
/// `@MainActor @Observable` for progress display only: all classification work
/// runs in a detached `.utility` task, so MainActor is never blocked.
@MainActor
@Observable
final class ClassificationEngine {
  private(set) var isClassifying = false
  private(set) var progress: String = ""
  private(set) var classifiedCount = 0
  private(set) var totalToClassify = 0

  /// Number of entries classified in the most recently finished batch.
  /// Captured from `classifiedCount` at the true→false transition of
  /// `isClassifying` so `ContentView` can skip article-list refreshes for
  /// polling ticks that had nothing to classify.
  private(set) var lastBatchClassifiedCount = 0

  /// The outcome of the most recent batch attempt, `nil` when that attempt
  /// ended cleanly. It means exactly that, not "the configuration is broken":
  /// a zero-pending poll clears it even while the configuration is still bad,
  /// and the next arriving article re-trips it. Never persisted, and never
  /// cleared eagerly by Settings — the poll is the save-time verification.
  ///
  /// The first mid-batch snapshot carrying evidence of progress also clears
  /// it, so a resumed drain does not keep a stale banner alive until drain
  /// end. An entry that completes without a provider call counts as progress.
  private(set) var lastAbort: ClassificationAbortReason?

  /// Monotonic counter bumped on every non-terminal progress snapshot while a
  /// batch is in flight, so `ContentView` can route a deferred article-list
  /// refresh mid-batch. The runner's throttle rate-limits the bumps. The
  /// terminal snapshot does not bump — the `isClassifying` false edge already
  /// covers it.
  private(set) var batchProgressVersion: Int = 0

  /// The single slot that owns whatever classification work is in flight.
  /// Every entry point routes through it, so only one runner is ever active
  /// and a manual trigger cannot race the polling loop into duplicate provider
  /// calls.
  private var classificationTask: Task<Void, Never>?
  /// Unique ID per stored task, so an awaiting one-shot entry point can clear
  /// the slot without clobbering a newer task. `Task` is a value type, so `===`
  /// is not available.
  private var classificationTaskID: UUID?

  /// User-intent flag: true between `startContinuousClassification` and
  /// `stopContinuousClassification`. `reclassifyAll` uses it to decide whether
  /// to restart the polling loop after the reset+batch completes.
  private var isContinuousModeActive = false

  /// Test-only provider factory. When non-nil, `makeRunner` uses it instead of
  /// `buildProvider()`, so a test injects a fake provider without touching
  /// `UserDefaults` or the Keychain. Production leaves it nil.
  private let providerFactoryOverride: (@Sendable () -> any ClassificationProvider)?

  // MARK: - Initializer

  /// The default argument keeps every production call site at
  /// `ClassificationEngine()`. A test passes a factory so the engine bypasses
  /// `buildProvider()`, which reads `UserDefaults` and the Keychain.
  init(providerFactoryOverride: (@Sendable () -> any ClassificationProvider)? = nil) {
    self.providerFactoryOverride = providerFactoryOverride
  }

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

  /// Manual trigger for classifying unclassified entries. Takes over the
  /// `classificationTask` slot, so a manual call gives immediate feedback
  /// without a parallel runner duplicating provider calls.
  func classifyUnclassified(writer: DataWriter) async {
    let runner = makeRunner(writer: writer)
    let cutoff = articleCutoffDate()
    await runReplacingContinuousLoop(writer: writer) {
      await runner.runOneBatch(cutoffDate: cutoff)
    }
  }

  /// Destructive one-shot: resets every classification and re-classifies from
  /// scratch. Exclusive by construction, and it restores the polling loop.
  func reclassifyAll(writer: DataWriter) async {
    let runner = makeRunner(writer: writer)
    let cutoff = articleCutoffDate()
    await runReplacingContinuousLoop(writer: writer) {
      await runner.runResetAndOneBatch(cutoffDate: cutoff)
    }
  }

  /// Cancel the polling loop, run `work` exclusively in the
  /// `classificationTask` slot, then restart the loop if it was running.
  private func runReplacingContinuousLoop(
    writer: DataWriter,
    _ work: @escaping @Sendable () async -> Void
  ) async {
    let shouldRestartContinuous = isContinuousModeActive
    classificationTask?.cancel()
    await classificationTask?.value
    classificationTask = nil
    classificationTaskID = nil
    isContinuousModeActive = false

    await runExclusively(work)

    if shouldRestartContinuous {
      startContinuousClassification(writer: writer)
    }
  }

  /// Run classification work exclusively in the `classificationTask` slot.
  /// UUID-tagged, so the slot is cleared only when no newer task has taken it
  /// and a stale one-shot cannot nil out a fresh continuous loop.
  private func runExclusively(_ work: @escaping @Sendable () async -> Void) async {
    let id = UUID()
    let task = Task.detached(priority: .utility) {
      await work()
    }
    classificationTask = task
    classificationTaskID = id
    await task.value
    if classificationTaskID == id {
      classificationTask = nil
      classificationTaskID = nil
    }
  }

  // MARK: - Test introspection
  //
  // Read-only accessors for the orchestration state the tests assert on.
  // `#if DEBUG` strips them from a Release build. The engine's own logic must
  // keep reading the private storage directly, so no production path depends
  // on this surface.

  #if DEBUG
    var isContinuousLoopActive: Bool { isContinuousModeActive }
    var currentClassificationTaskID: UUID? { classificationTaskID }
    /// How many times `apply(_:)` actually wrote `lastAbort`, so the
    /// same-value no-rewrite guard can be asserted without Observation
    /// plumbing.
    private(set) var lastAbortWriteCount = 0
  #endif

  // MARK: - MainActor sink for progress snapshots

  private func apply(_ snapshot: ProgressSnapshot) {
    // Capture the finished batch's count before the terminal snapshot resets
    // `classifiedCount`. `ContentView` reads it to decide whether the tick
    // changed anything.
    if isClassifying && !snapshot.isClassifying {
      lastBatchClassifiedCount = classifiedCount
    }
    // Only a batch-outcome terminal owns the abort field. The equality guard
    // stops `@Observable` same-value churn on the poll cadence: rewriting an
    // unchanged value re-announces the banner to VoiceOver on every tick.
    if !snapshot.isClassifying, snapshot.ownsAbort, lastAbort != snapshot.abort {
      lastAbort = snapshot.abort
      #if DEBUG
        lastAbortWriteCount += 1
      #endif
    }
    // Evidence of progress: an abortable failure throws before any persist, so
    // a non-zero count proves the banner's cause is not occurring now. The
    // `lastAbort != nil` guard keeps the banner steady in a persistently
    // failing retry loop, where the count stays 0.
    if snapshot.isClassifying, snapshot.classifiedCount > 0, lastAbort != nil {
      lastAbort = nil
      #if DEBUG
        lastAbortWriteCount += 1
      #endif
    }
    // Only a non-terminal snapshot bumps: `ContentView` already covers the
    // terminal false edge through `isClassifying`.
    if snapshot.isClassifying {
      batchProgressVersion &+= 1
    }
    isClassifying = snapshot.isClassifying
    progress = snapshot.progress
    classifiedCount = snapshot.classifiedCount
    totalToClassify = snapshot.totalToClassify
  }

  // MARK: - Runner factory

  /// Build a runner. The progress reporter captures `self` strongly: the
  /// detached task owns the runner and `classificationTask?.cancel()` bounds
  /// its lifetime, so there is no retain cycle.
  private func makeRunner(writer: DataWriter) -> ClassificationRunner {
    let reporter: @Sendable (ProgressSnapshot) async -> Void = { snapshot in
      await MainActor.run { self.apply(snapshot) }
    }
    // The provider is built per batch, so a Settings change takes effect on the
    // next polling cycle with no stop-and-start round-trip.
    let providerFactory: @Sendable () -> any ClassificationProvider =
      providerFactoryOverride ?? { Self.buildProvider() }
    return ClassificationRunner(
      writer: writer, providerFactory: providerFactory, reportProgress: reporter
    )
  }

  // MARK: - Preview / test seam

  /// Seed the engine's observable state for SwiftUI previews. Production never
  /// calls it; the seam lives here so `private(set)` stays tight on the real
  /// fields.
  ///
  /// Not gated behind `#if DEBUG`: preview helpers reach it from types that
  /// must still type-check in Release, even though the `#Preview` body is
  /// stripped.
  func applyPreviewState(
    isClassifying: Bool = false,
    progress: String = "",
    classifiedCount: Int = 0,
    totalToClassify: Int = 0,
    lastAbort: ClassificationAbortReason? = nil
  ) {
    self.isClassifying = isClassifying
    self.progress = progress
    self.classifiedCount = classifiedCount
    self.totalToClassify = totalToClassify
    self.lastAbort = lastAbort
  }

  // MARK: - Provider factory

  /// Resolve the configured classification provider from `UserDefaults` and
  /// the Keychain. `nonisolated`, so a background task can call it per batch.
  ///
  /// The Keychain lookup runs only when the user has chosen OpenAI, and only
  /// once the batch starts, so a user on Apple Foundation Models never
  /// triggers a Keychain prompt.
  ///
  /// With OpenAI selected but no key stored, fall back to the on-device
  /// provider for this batch: an empty-key provider would fail `isAvailable`
  /// and swallow the batch silently. The next batch picks up a key as soon as
  /// the user saves one.
  nonisolated static func buildProvider(
    defaults: UserDefaults = .standard,
    keychainLoad: (String) -> String? = { KeychainHelper.load(key: $0) }
  ) -> any ClassificationProvider {
    switch ClassificationProviderKind.current(in: defaults) {
    case .openAI:
      guard let apiKey = keychainLoad(KeychainHelper.openAIAPIKeychainKey),
        !apiKey.isEmpty
      else {
        return AppleFMClassificationProvider()
      }
      return OpenAIClassificationProvider(
        apiKey: apiKey,
        model: OpenAIModelSetting.current(in: defaults)
      )
    case .appleFM:
      return AppleFMClassificationProvider()
    }
  }
}

// MARK: - Classification Runner (nonisolated, runs on background task)

/// Executes the classification loop entirely off MainActor, from a `.utility`
/// detached task. Progress reaches MainActor through the `Sendable`
/// `reportProgress` closure, throttled to one call per 200 ms.
nonisolated struct ClassificationRunner: Sendable {
  let writer: DataWriter
  /// Resolved per batch, so a provider or key change in Settings takes effect
  /// without a restart.
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

  /// Drain every pending-classification entry in bounded chunks of
  /// `chunkSize`. The reported denominator is `processedCount + remaining`,
  /// and `remaining` is re-seeded from a fresh count at each chunk boundary, so
  /// the total grows as sync persists more entries mid-drain. Query the count
  /// only at a chunk boundary, never on the display tick, or the added SQLite
  /// work passes the per-page write cadence (`STACK.md § 4`).
  func runOneBatch(cutoffDate: Date, chunkSize: Int = 50) async {
    guard let categories = try? await writer.fetchCategoryDefinitions(),
      !categories.isEmpty
    else { return }

    // Peek the first chunk. Nothing pending clears a leftover spinner and
    // stops.
    guard
      let firstChunk = try? await writer.fetchUnclassifiedInputs(
        cutoffDate: cutoffDate, limit: chunkSize),
      !firstChunk.isEmpty
    else {
      // Zero-pending is a batch outcome: it owns the field and clears a stale
      // abort banner.
      await reportProgress(.outcome(nil))
      return
    }

    let provider = providerFactory()
    guard await provider.isAvailable else {
      logger.error("Classification provider '\(provider.name)' not available")
      // A batch outcome, not a plain terminal: it makes provider
      // unavailability visible and keeps a live banner while the provider
      // stays unusable.
      await reportProgress(.outcome(.providerUnavailable))
      return
    }

    let providerName = provider.name
    let instructions = buildClassificationInstructions(from: categories)
    let validLabels = Set(categories.map(\.label))
    let supportedLangCodes = await provider.supportedLanguageCodes

    // Live pending count behind the reported denominator.
    var remaining =
      (try? await writer.countUnclassifiedEntries(cutoffDate: cutoffDate)) ?? firstChunk.count
    var processedCount = 0
    // Rows already attempted this drain. An entry that fails to persist stays
    // unclassified and reappears in the next chunk fetch, so skipping
    // attempted IDs lets the drain terminate and leaves the retry to the next
    // poll.
    var attemptedIDs = Set<Int>()
    var lastProgressUpdate: ContinuousClock.Instant = .now

    logger.info(
      "Classifying \(remaining) pending entries with \(categories.count) categories using \(providerName)"
    )

    await reportProgress(
      ProgressSnapshot(
        isClassifying: true,
        progress: "Categorizing 0/\(processedCount + remaining) (\(providerName))",
        classifiedCount: 0,
        totalToClassify: processedCount + remaining
      )
    )

    var chunk = firstChunk
    drain: while !chunk.isEmpty {
      if Task.isCancelled { break }

      let pending = chunk.filter { !attemptedIDs.contains($0.entryID) }
      // Every row in the chunk was already attempted, so the next poll
      // retries.
      if pending.isEmpty { break }

      for input in pending {
        if Task.isCancelled { break drain }
        attemptedIDs.insert(input.entryID)

        let result: ClassificationResult
        if shouldSkipClassification(title: input.title, body: input.body) {
          result = ClassificationResult(
            entryID: input.entryID,
            categoryLabel: uncategorizedLabel,
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
              confidence: 0.0
            )
          } else {
            do {
              let providerResult = try await provider.classify(
                title: input.title,
                body: input.body,
                url: input.url,
                instructions: instructions
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
                confidence: providerResult.confidence
              )
            } catch {
              if let reason = (error as? any ClassificationFailure)?.batchAbort {
                // Deterministic provider-level failure: persist nothing for
                // this entry or the remainder, so they stay unclassified and
                // the next poll retries. Only the payload-free reason reaches
                // the UI; the detail stays in this `.private` line.
                logger.error(
                  "Classification provider '\(providerName)' failed, aborting batch: \(String(describing: error), privacy: .private)"
                )
                await reportProgress(.outcome(reason))
                return
              }
              result = ClassificationResult(
                entryID: input.entryID,
                categoryLabel: uncategorizedLabel,
                confidence: 0.0
              )
            }
          }
        }

        try? await writer.applyClassification(entryID: result.entryID, result: result)

        processedCount += 1
        remaining = max(0, remaining - 1)
        let now = ContinuousClock.now
        if now - lastProgressUpdate >= .milliseconds(200) {
          await reportProgress(
            ProgressSnapshot(
              isClassifying: true,
              progress: "Categorizing \(processedCount)/\(processedCount + remaining) (\(providerName))",
              classifiedCount: processedCount,
              totalToClassify: processedCount + remaining
            )
          )
          lastProgressUpdate = now
        }
      }

      if Task.isCancelled { break }
      // Chunk boundary: pull the next chunk and re-seed the pending count.
      chunk =
        (try? await writer.fetchUnclassifiedInputs(cutoffDate: cutoffDate, limit: chunkSize)) ?? []
      remaining = (try? await writer.countUnclassifiedEntries(cutoffDate: cutoffDate)) ?? chunk.count
    }

    // On a clean drain, emit one final snapshot with the pending count spent,
    // so the two numbers match at the moment the queue empties. Skipped on
    // cancellation, where the terminal snapshot below clears the spinner.
    if !Task.isCancelled {
      await reportProgress(
        ProgressSnapshot(
          isClassifying: true,
          progress: "Categorizing \(processedCount)/\(processedCount) (\(providerName))",
          classifiedCount: processedCount,
          totalToClassify: processedCount
        )
      )
    }

    logger.info("Classification batch complete: \(processedCount) entries")
    if Task.isCancelled {
      // A cancelled batch is not an outcome, so the plain terminal preserves a
      // live banner. A manual trigger replaces the continuous loop mid-batch,
      // and an owning nil here would clear the banner and re-trip it.
      await reportProgress(.terminal)
    } else {
      await reportProgress(.outcome(nil))
    }
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
