import Foundation
import FoundationModels
import Testing

@testable import Feeder

/// Answers each `generate` call with the next script entry. The last entry
/// repeats.
actor AppleFMGenerateScript {
  private let script: [Result<ProviderClassificationResult, any Error>]
  private(set) var callCount = 0

  init(_ script: [Result<ProviderClassificationResult, any Error>]) {
    precondition(!script.isEmpty, "A generate script needs at least one entry")
    self.script = script
  }

  func generate() throws -> ProviderClassificationResult {
    callCount += 1
    return try script[min(callCount, script.count) - 1].get()
  }
}

actor InstructionMeasureRecorder {
  private let measure: AppleFMClassificationProvider.InstructionMeasure
  private(set) var instructions: [String] = []

  init(_ measure: AppleFMClassificationProvider.InstructionMeasure) { self.measure = measure }

  func record(_ text: String) -> AppleFMClassificationProvider.InstructionMeasure {
    instructions.append(text)
    return measure
  }
}

/// A test must build model values only and never call the system model.
@MainActor
@Suite("Apple Foundation Models failure policy")
struct AppleFMProviderPolicyTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_000_000)
  nonisolated private static let context = LanguageModelSession.GenerationError.Context(debugDescription: "context")
  nonisolated private static let success = ProviderClassificationResult.generative(category: "tech", confidence: 0.9)
  nonisolated private static let fits = AppleFMClassificationProvider.InstructionMeasure(tokenCount: 100, contextSize: 4096)
  nonisolated private static let rateLimit: any Error = LanguageModelSession.GenerationError.rateLimited(context)
  nonisolated private static let guardrail: any Error = LanguageModelSession.GenerationError.guardrailViolation(context)

  private func provider(
    _ script: AppleFMGenerateScript,
    clock: ClassificationSleepRecorder = ClassificationSleepRecorder(immediateDelays: .max),
    availability: SystemLanguageModel.Availability = .available,
    measure: InstructionMeasureRecorder = InstructionMeasureRecorder(fits)
  ) -> AppleFMClassificationProvider {
    AppleFMClassificationProvider(
      availability: { availability },
      languageCodes: { ["en"] },
      measureInstructions: { await measure.record($0) },
      generate: { _, _, _, _ in try await script.generate() },
      sleep: { try await clock.sleep($0) },
      now: { Self.now })
  }

  private func classify(_ provider: AppleFMClassificationProvider) async throws -> ProviderClassificationResult {
    try await provider.classify(title: "Title", body: "Body", url: "https://example.com", categories: [])
  }

  private func classifyFailure(_ provider: AppleFMClassificationProvider) async -> AppleFMClassificationError? {
    do {
      _ = try await classify(provider)
      return nil
    } catch {
      return error as? AppleFMClassificationError
    }
  }

  private func fixture(entryCount: Int) async throws -> DataWriter {
    let writer = try await DataWriterTestSupport.makeWriter()
    try await writer.addCategory(label: "tech", displayName: "Tech", description: "Technology", sortOrder: 0)
    try await writer.addCategory(label: uncategorizedLabel, displayName: "Uncategorized", description: "Fallback", sortOrder: 1)
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    let date = ISO8601DateFormatter().string(from: Date())
    let ids = Array(1001..<(1001 + entryCount))
    let entries = try ids.map {
      try FeedbinFixtures.entry(id: $0, title: "An article", content: "<p>Some article text</p>", published: date)
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
    return writer
  }

  private func runOneBatch(
    _ writer: DataWriter, provider: AppleFMClassificationProvider
  ) async -> (ClassificationBatchOutcome, [ClassificationAbortReason?]) {
    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(writer: writer, providerFactory: { provider }, reportProgress: { await recorder.record($0) })
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast)
    return (outcome, await recorder.snapshots.filter(\.ownsAbort).map(\.abort))
  }

  /// Returns the count of uncategorized entries and of pending entries.
  private func assignmentCounts(_ writer: DataWriter, ids: ClosedRange<Int>) async throws -> (uncategorized: Int, pending: Int) {
    var uncategorized = 0
    var pending = 0
    for id in ids {
      let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
      if !entry.isClassified { pending += 1 } else if entry.primaryCategory == uncategorizedLabel { uncategorized += 1 }
    }
    return (uncategorized, pending)
  }

  // MARK: - Availability

  nonisolated private static let unavailableCauses: [SystemLanguageModel.Availability.UnavailableReason] = [
    .appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady,
  ]

  @Test(arguments: AppleFMProviderPolicyTests.unavailableCauses)
  func everyUnavailabilityCauseHasTheAppleIntelligenceReason(_ cause: SystemLanguageModel.Availability.UnavailableReason) {
    #expect(AppleFMClassificationProvider.abortReason(for: .unavailable(cause)) == .appleIntelligenceUnavailable)
  }

  @Test
  func availableModelHasNoReason() {
    #expect(AppleFMClassificationProvider.abortReason(for: .available) == nil)
  }

  @Test
  func unavailableModelStopsTheDrainWithTheAppleIntelligenceReason() async throws {
    let writer = try await fixture(entryCount: 2)
    let script = AppleFMGenerateScript([.success(Self.success)])
    let measure = InstructionMeasureRecorder(Self.fits)
    let provider = provider(script, availability: .unavailable(.appleIntelligenceNotEnabled), measure: measure)
    let (outcome, aborts) = await runOneBatch(writer, provider: provider)
    guard case .aborted(.poll, completed: 0) = outcome else {
      Issue.record("Expected a poll abort, got \(outcome)")
      return
    }
    #expect(aborts == [.appleIntelligenceUnavailable])
    #expect(await script.callCount == 0)
    #expect(await measure.instructions.isEmpty, "An unavailable model must skip the size check")
  }

  @Test
  func modelLostDuringARateLimitStopsWithoutARetry() async {
    let script = AppleFMGenerateScript([.failure(Self.rateLimit)])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = provider(script, clock: clock, availability: .unavailable(.modelNotReady))
    #expect(await classifyFailure(provider) == .modelUnavailable)
    #expect(await clock.delays.isEmpty)
    #expect(await script.callCount == 1)
  }

  // MARK: - Instruction size

  @Test(arguments: [(3896, true), (3897, false)])
  func instructionsFitBelowTheOutputReserve(tokenCount: Int, fits: Bool) {
    let measure = AppleFMClassificationProvider.InstructionMeasure(tokenCount: tokenCount, contextSize: 4096)
    #expect(AppleFMClassificationProvider.instructionsFit(measure) == fits)
  }

  @Test
  func validateMeasuresTheInstructionsWithAnEmptyPrompt() async throws {
    let measure = InstructionMeasureRecorder(Self.fits)
    let provider = provider(AppleFMGenerateScript([.success(Self.success)]), measure: measure)
    let categories = [CategoryDefinition(label: "tech", description: "Technology", keywords: [])]
    try await provider.validate(categories: categories)
    #expect(await measure.instructions == [buildClassificationInstructions(from: categories) + "title: \nurl: \ncontent: "])
  }

  @Test
  func oversizedInstructionsBlockTheDrainBeforeAnyRequest() async throws {
    let writer = try await fixture(entryCount: 2)
    let script = AppleFMGenerateScript([.success(Self.success)])
    let measure = InstructionMeasureRecorder(.init(tokenCount: 5000, contextSize: 4096))
    let (outcome, aborts) = await runOneBatch(writer, provider: provider(script, measure: measure))
    guard case .aborted(.blocked, completed: 0) = outcome else {
      Issue.record("Expected a blocked abort, got \(outcome)")
      return
    }
    #expect(aborts == [.inputTooLarge])
    #expect(await script.callCount == 0)
    #expect(try await assignmentCounts(writer, ids: 1001...1002).pending == 2)
  }

  // MARK: - Rate limit retry

  @Test
  func rateLimitRetriesTheSameArticleWithAGrowingWait() async throws {
    let script = AppleFMGenerateScript([.failure(Self.rateLimit), .failure(Self.rateLimit), .success(Self.success)])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(try await classify(provider(script, clock: clock)) == Self.success)
    #expect(await clock.delays == [.seconds(2), .seconds(4)])
    #expect(await script.callCount == 3)
  }

  @Test
  func rateLimitRetryIsBounded() async {
    let script = AppleFMGenerateScript([.failure(Self.rateLimit)])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(await classifyFailure(provider(script, clock: clock)) == .rateLimited(retryAfter: nil))
    #expect(await clock.delays == [.seconds(2), .seconds(4)])
    #expect(await script.callCount == 3)
  }

  @Test
  func cancellationEndsTheRetryWait() async throws {
    let script = AppleFMGenerateScript([.failure(Self.rateLimit), .success(Self.success)])
    let clock = ClassificationSleepRecorder()
    let provider = provider(script, clock: clock)
    let task = Task { try await classify(provider) }
    try await waitUntil("the retry wait starts") { await clock.delays.count == 1 }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await script.callCount == 1)
  }

  @available(macOS 27.0, *)
  @Test
  func shortResetDateExtendsTheRetryWait() async throws {
    let error = LanguageModelError.rateLimited(.init(resetDate: Self.now.addingTimeInterval(5), debugDescription: "rate limit"))
    let script = AppleFMGenerateScript([.failure(error), .success(Self.success)])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(try await classify(provider(script, clock: clock)) == Self.success)
    #expect(await clock.delays == [.seconds(5)])
  }

  @available(macOS 27.0, *)
  @Test
  func longResetDateStopsAtOnceAndKeepsTheWait() async {
    let error = LanguageModelError.rateLimited(.init(resetDate: Self.now.addingTimeInterval(30), debugDescription: "rate limit"))
    let script = AppleFMGenerateScript([.failure(error)])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(await classifyFailure(provider(script, clock: clock)) == .rateLimited(retryAfter: 30))
    #expect(await clock.delays.isEmpty)
    #expect(await script.callCount == 1)
  }

  // MARK: - Guardrail streak

  @Test
  func thirdConsecutiveGuardrailFailureDeclinesTheCategories() async {
    let provider = provider(AppleFMGenerateScript([.failure(Self.guardrail)]))
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == .categoriesDeclined)
  }

  @Test
  func anotherOutcomeResetsTheGuardrailStreak() async {
    let script = AppleFMGenerateScript([
      .failure(Self.guardrail), .failure(Self.guardrail), .success(Self.success), .failure(Self.guardrail), .failure(Self.guardrail),
    ])
    let provider = provider(script)
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == nil)
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == .guardrailViolation)
  }

  @Test
  func validateStartsANewGuardrailStreak() async throws {
    let provider = provider(AppleFMGenerateScript([.failure(Self.guardrail)]))
    #expect(await classifyFailure(provider) == .guardrailViolation)
    #expect(await classifyFailure(provider) == .guardrailViolation)
    try await provider.validate(categories: [])
    #expect(await classifyFailure(provider) == .guardrailViolation)
  }

  @Test
  func twoGuardrailFailuresKeepThePerEntryFallback() async throws {
    let writer = try await fixture(entryCount: 4)
    let script = AppleFMGenerateScript([
      .failure(Self.guardrail), .failure(Self.guardrail), .success(Self.success), .success(Self.success),
    ])
    let (outcome, aborts) = await runOneBatch(writer, provider: provider(script))
    guard case .completed(4) = outcome else {
      Issue.record("Expected a completed drain, got \(outcome)")
      return
    }
    #expect(aborts == [nil])
    let counts = try await assignmentCounts(writer, ids: 1001...1004)
    #expect(counts.uncategorized == 2)
    #expect(counts.pending == 0)
  }

  @Test
  func threeGuardrailFailuresStopTheDrainAndKeepTheRestPending() async throws {
    let writer = try await fixture(entryCount: 5)
    let script = AppleFMGenerateScript([.failure(Self.guardrail)])
    let (outcome, aborts) = await runOneBatch(writer, provider: provider(script))
    guard case .aborted(.blocked, completed: 2) = outcome else {
      Issue.record("Expected a blocked abort after two entries, got \(outcome)")
      return
    }
    #expect(aborts == [.categoriesDeclined])
    #expect(await script.callCount == 3)
    let counts = try await assignmentCounts(writer, ids: 1001...1005)
    #expect(counts.uncategorized == 2)
    #expect(counts.pending == 3)
  }

  // MARK: - App activation

  private func engineWaitingAfterAStop(
    _ writer: DataWriter
  ) async throws -> (ClassificationEngine, FakeClassificationProvider, ClassificationSleepRecorder) {
    let provider = FakeClassificationProvider()
    await provider.configureErrors(FakeClassificationFailure(batchAbort: .rateLimited), count: 1)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("the loop wait starts") { await clock.delays.count == 1 }
    return (engine, provider, clock)
  }

  @Test
  func activationEndsTheLoopWaitAfterAnAppleFMRateLimit() async throws {
    let writer = try await fixture(entryCount: 2)
    let (engine, provider, clock) = try await engineWaitingAfterAStop(writer)
    engine.applyPreviewState(lastAbort: .rateLimited, provider: .appleFM)
    engine.applicationDidBecomeActive()
    try await waitUntil("the restarted drain completes") { await clock.delays.count == 2 }
    #expect(await provider.callCount == 3)
    #expect(engine.lastAbort == nil)
    for id in 1001...1002 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.primaryCategory == "tech") }
    engine.stopContinuousClassification()
  }

  nonisolated private static let statesWithoutRestart: [(ClassificationAbortReason?, ClassificationProviderKind)] = [
    (.rateLimited, .vercel),
    (.rateLimited, .openAI),
    (.categoriesDeclined, .appleFM),
    (.inputTooLarge, .appleFM),
    (nil, .appleFM),
  ]

  @Test(arguments: AppleFMProviderPolicyTests.statesWithoutRestart)
  func activationKeepsEveryOtherWait(abort: ClassificationAbortReason?, provider kind: ClassificationProviderKind) async throws {
    let writer = try await fixture(entryCount: 2)
    let (engine, provider, _) = try await engineWaitingAfterAStop(writer)
    engine.applyPreviewState(lastAbort: abort, provider: kind)
    let taskID = engine.currentClassificationTaskID
    engine.applicationDidBecomeActive()
    #expect(engine.currentClassificationTaskID == taskID)
    #expect(await provider.callCount == 1)
    engine.stopContinuousClassification()
  }

  @Test
  func activationDoesNotStartAStoppedLoop() {
    let engine = ClassificationEngine(providerFactoryOverride: { FakeClassificationProvider() })
    engine.applyPreviewState(lastAbort: .rateLimited, provider: .appleFM)
    engine.applicationDidBecomeActive()
    #expect(engine.currentClassificationTaskID == nil)
  }
}
