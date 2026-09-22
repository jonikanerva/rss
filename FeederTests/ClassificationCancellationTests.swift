import Foundation
import Testing

@testable import Feeder

@MainActor
@Suite("Classification cancellation and retry timelines")
struct ClassificationCancellationTests {
  private func fixture() async throws -> DataWriter {
    let writer = try await DataWriterTestSupport.makeWriter()
    try await writer.addCategory(label: "tech", displayName: "Tech", description: "Technology", sortOrder: 0)
    try await writer.addCategory(label: uncategorizedLabel, displayName: "Uncategorized", description: "Fallback", sortOrder: 1)
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    let date = ISO8601DateFormatter().string(from: Date())
    let entries = try (1001...1003).map {
      try FeedbinFixtures.entry(id: $0, title: "An article", content: "<p>Some article text</p>", published: date)
    }
    _ = try await writer.persistEntries(entries, unreadIDs: [1001, 1002, 1003])
    return writer
  }

  @Test
  func cancelledActorCallsCannotApplyOrResetAnyFields() async throws {
    let writer = try await fixture()
    for id in 1001...1003 {
      try await writer.applyClassification(entryID: id, result: .init(entryID: id, categoryLabel: "tech", confidence: 0.9))
    }
    var initial: [Int: EntrySnapshot] = [:]
    for id in 1001...1003 { initial[id] = try await writer.fetchEntrySnapshot(feedbinEntryID: id) }
    let apply = Task { @MainActor in
      try await writer.applyClassification(entryID: 1001, result: .init(entryID: 1001, categoryLabel: uncategorizedLabel, confidence: nil))
    }
    apply.cancel()
    await #expect(throws: CancellationError.self) { try await apply.value }
    let reset = Task { @MainActor in try await writer.resetClassification() }
    reset.cancel()
    await #expect(throws: CancellationError.self) { try await reset.value }
    for id in 1001...1003 {
      let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
      #expect(entry == initial[id])
    }
  }

  @Test
  func localPreflightFailureKeepsExistingAssignments() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    await engine.classifyUnclassified(writer: writer)
    for error in [VercelClassificationError.needsKey, .invalidCategories, .inputTooLarge] {
      await provider.configureValidation(error)
      await engine.reclassifyAll(writer: writer)
      #expect(engine.lastAbort == error.batchAbort)
      for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.primaryCategory == "tech") }
    }
    #expect(await provider.callCount == 3)
  }

  @Test
  func cancelledProviderResultNeverPersists() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureDelay(.seconds(5))
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("provider request starts") { await provider.callCount == 1 }
    engine.stopContinuousClassification()
    try await Task.sleep(for: .milliseconds(20))
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == false) }
    #expect(!engine.isClassifying)
  }

  @Test
  func rapidConfigurationChangesOnlyRunTheLatestReplacement() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureDelay(.seconds(5))
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("first request starts") { await provider.callCount == 1 }
    await provider.configureDelay(.zero)
    engine.configurationChanged(writer: writer)
    engine.configurationChanged(writer: writer)
    engine.configurationChanged(writer: writer)
    try await waitUntil("latest replacement completes") {
      let count = await provider.callCount
      let active = await engine.isClassifying
      return count == 4 && !active
    }
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == true) }
    engine.stopContinuousClassification()
    #expect(engine.lastAbort == nil)
  }

  @Test
  func malformedResponseLeavesTheWholeDrainPending() async throws {
    let writer = try await fixture()
    let recorder = ClassificationTransportRecorder(data: Data("{}".utf8))
    let provider = VercelClassificationProvider(apiKey: "fake", send: { await recorder.send($0) })
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    await engine.classifyUnclassified(writer: writer)
    #expect(await recorder.requests.count == 1)
    #expect(engine.lastAbort == .invalidResponse)
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == false) }
  }

  @Test
  func exhaustedBudgetPausesWithoutPersistingFallback() async throws {
    let writer = try await fixture()
    let recorder = ClassificationTransportRecorder(data: Data(), status: 402)
    let provider = VercelClassificationProvider(apiKey: "fake", send: { await recorder.send($0) })
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    await engine.classifyUnclassified(writer: writer)
    #expect(await recorder.requests.count == 1)
    #expect(engine.lastAbort == .rateLimited)
    #expect(VercelClassificationError.http(402, retryAfter: nil).retryDisposition == .transient(retryAfter: nil))
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == false) }
  }

  @Test
  func deterministicFailureWaitsUntilManualRetryWithoutReset() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(VercelClassificationError.http(401, retryAfter: nil), count: 1, afterSuccesses: 1)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("blocked wait reached") { await clock.delays.count == 1 }
    #expect(await provider.callCount == 2)
    #expect(await clock.delays == [.seconds(3600)])
    #expect(engine.lastAbort == .keyRejected)
    #expect(engine.lastBatchClassifiedCount == 1)
    await engine.classifyUnclassified(writer: writer)
    #expect(await provider.callCount == 4)
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == true) }
    engine.stopContinuousClassification()
  }

  @Test
  func openAIKeyRejectionWaitsForManualRetry() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(
      OpenAIError.apiError(statusCode: 401, message: "x", retryAfter: nil), count: 1, afterSuccesses: 1)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("blocked wait reached") { await clock.delays.count == 1 }
    #expect(await clock.delays == [.seconds(3600)])
    #expect(await provider.callCount == 2)
    #expect(engine.lastAbort == .keyRejected)
    #expect(engine.lastBatchClassifiedCount == 1)
    var classified = 0
    for id in 1001...1003 where try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == true {
      classified += 1
    }
    #expect(classified == 1)
    await engine.classifyUnclassified(writer: writer)
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.isClassified == true) }
    engine.stopContinuousClassification()
  }

  @Test
  func perArticleRejectionKeepsTheDrainMoving() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(
      OpenAIError.entryRejected(code: "context_length_exceeded"), count: 1, afterSuccesses: 1)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("drain finished") { await clock.delays.count == 1 }
    #expect(await provider.callCount == 3)
    #expect(await clock.delays == [.seconds(2)])
    #expect(engine.lastAbort == nil)
    var uncategorized = 0
    var tech = 0
    for id in 1001...1003 {
      let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
      #expect(entry.isClassified == true)
      if entry.primaryCategory == uncategorizedLabel { uncategorized += 1 }
      if entry.primaryCategory == "tech" { tech += 1 }
    }
    #expect(uncategorized == 1)
    #expect(tech == 2)
    engine.stopContinuousClassification()
  }

  @Test
  func continuousLoopKeepsBackoffAcrossFailedBatches() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(VercelClassificationError.network, count: 5)
    let clock = ClassificationSleepRecorder(immediateDelays: 5)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("all retry delays recorded") { await clock.delays.count == 6 }
    #expect(await clock.delays == [.seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(300), .seconds(2)])
    #expect(await provider.callCount == 8)
    #expect(engine.lastAbort == nil)
    engine.stopContinuousClassification()
  }

  @Test
  func configurationChangeInterruptsBackoff() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(VercelClassificationError.network, count: 1)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("backoff reached") { await clock.delays.count == 1 }
    #expect(await clock.delays == [.seconds(30)])
    #expect(await provider.callCount == 1)
    engine.configurationChanged(writer: writer)
    try await waitUntil("replacement completes") {
      let count = await provider.callCount
      let active = await engine.isClassifying
      return count == 4 && !active
    }
    #expect(engine.lastAbort == nil)
    engine.stopContinuousClassification()
  }
}

actor ClassificationSleepRecorder {
  private(set) var delays: [Duration] = []
  private let immediateDelays: Int

  init(immediateDelays: Int = 0) { self.immediateDelays = immediateDelays }

  func sleep(_ delay: Duration) async throws {
    delays.append(delay)
    try Task.checkCancellation()
    if delays.count <= immediateDelays { return }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    for await _ in stream { break }
    try Task.checkCancellation()
  }
}
