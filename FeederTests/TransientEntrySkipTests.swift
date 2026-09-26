import Foundation
import Testing

@testable import Feeder

@MainActor
@Suite("Transient entry skip timelines")
struct TransientEntrySkipTests {
  nonisolated private static let timeout = OpenAIError.networkUnavailable(underlying: URLError(.timedOut))

  private func makeWriter() async throws -> DataWriter {
    let writer = try await DataWriterTestSupport.makeWriter()
    try await writer.addCategory(label: "tech", displayName: "Tech", description: "Technology", sortOrder: 0)
    try await writer.addCategory(label: uncategorizedLabel, displayName: "Uncategorized", description: "Fallback", sortOrder: 1)
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    return writer
  }

  /// Persists one pending article per title. Each title is one minute older
  /// than the title before it, so a drain fetches the titles in this order.
  @discardableResult
  private func persist(_ writer: DataWriter, _ titles: [String], firstID: Int, newest: Date = Date()) async throws -> [Int] {
    let formatter = ISO8601DateFormatter()
    let ids = Array(firstID..<(firstID + titles.count))
    let entries = try titles.indices.map { index in
      try FeedbinFixtures.entry(
        id: ids[index], title: titles[index], content: "<p>Some article text</p>",
        published: formatter.string(from: newest.addingTimeInterval(-60 * Double(index))))
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
    return ids
  }

  private func makeRunner(
    _ writer: DataWriter, provider: any ClassificationProvider, recorder: SnapshotRecorder = SnapshotRecorder()
  ) -> ClassificationRunner {
    ClassificationRunner(writer: writer, providerFactory: { provider }, reportProgress: { await recorder.record($0) })
  }

  private func expectPending(_ writer: DataWriter, id: Int) async throws {
    let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
    #expect(!entry.isClassified)
  }

  private func expectCategory(_ writer: DataWriter, id: Int, _ label: String) async throws {
    let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
    #expect(entry.isClassified)
    #expect(entry.primaryCategory == label)
  }

  // MARK: - Runner

  @Test
  func stuckArticleIsSkippedAndTheDrainContinues() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck", "Second", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    let recorder = SnapshotRecorder()
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider, recorder: recorder)
      .runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.completedCount == 2)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [nil])
    #expect(await provider.requestedTitles == ["Stuck", "Second", "Third"])
    try await expectPending(writer, id: ids[0])
    try await expectCategory(writer, id: ids[1], "tech")
    try await expectCategory(writer, id: ids[2], "tech")
    #expect(failures.strikes(for: ids[0]) == 1)
  }

  @Test
  func fallbackFollowsThreeCountedDrainsWithoutARequest() async throws {
    let writer = try await makeWriter()
    let start = Date().addingTimeInterval(-3600)
    let stuck = try await persist(writer, ["Stuck"], firstID: 1001, newest: start)[0]
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    let runner = makeRunner(writer, provider: provider)
    var failures = TransientEntryFailures()
    for drain in 1...3 {
      try await persist(writer, ["Newer \(drain)"], firstID: 2000 + drain, newest: start.addingTimeInterval(60 * Double(drain)))
      let outcome = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
      #expect(outcome.completedCount == 1)
      #expect(failures.strikes(for: stuck) == drain)
      try await expectPending(writer, id: stuck)
    }
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.completedCount == 1)
    #expect(await provider.requestedTitles.filter { $0 == "Stuck" }.count == 3)
    try await expectCategory(writer, id: stuck, uncategorizedLabel)
  }

  @Test
  func failureOnEveryArticleStopsAfterTwoRequestsAndGivesNoStrike() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Second", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureErrors(Self.timeout, count: .max)
    let recorder = SnapshotRecorder()
    let runner = makeRunner(writer, provider: provider, recorder: recorder)
    var failures = TransientEntryFailures()
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(await provider.callCount == 2)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [.offline])
    for _ in 2...4 { _ = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures) }
    #expect(await provider.callCount == 8)
    for id in ids {
      #expect(failures.strikes(for: id) == 0)
      #expect(!failures.requiresFallback(id))
      try await expectPending(writer, id: id)
    }
  }

  @Test
  func skippedArticlesGoLastInTheNextDrain() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck 1", "Stuck 2", "Backlog 1", "Backlog 2"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 1")
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 2")
    let runner = makeRunner(writer, provider: provider)
    var failures = TransientEntryFailures()
    let first = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(first.abortDisposition == .transient(retryAfter: nil))
    #expect(await provider.requestedTitles == ["Stuck 1", "Stuck 2"])
    let second = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(second.abortDisposition == .transient(retryAfter: nil))
    #expect(await provider.requestedTitles == ["Stuck 1", "Stuck 2", "Backlog 1", "Backlog 2", "Stuck 1", "Stuck 2"])
    #expect(failures.strikes(for: ids[0]) == 1)
    #expect(failures.strikes(for: ids[1]) == 1)
    try await expectCategory(writer, id: ids[2], "tech")
    try await expectCategory(writer, id: ids[3], "tech")
  }

  @Test
  func successBetweenTwoSkipsKeepsTheDrainGoing() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck 1", "Healthy", "Stuck 2", "Backlog"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 1")
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 2")
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider).runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.completedCount == 2)
    #expect(await provider.requestedTitles == ["Stuck 1", "Healthy", "Stuck 2", "Backlog"])
    #expect(failures.strikes(for: ids[0]) == 1)
    #expect(failures.strikes(for: ids[2]) == 1)
    try await expectCategory(writer, id: ids[3], "tech")
  }

  @Test
  func perEntryFallbackIsNotASuccess() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck 1", "Rejected", "Stuck 2", "Backlog"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 1")
    await provider.configureFailure(OpenAIError.entryRejected(code: "context_length_exceeded"), forTitle: "Rejected")
    await provider.configureFailure(Self.timeout, forTitle: "Stuck 2")
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider).runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(await provider.requestedTitles == ["Stuck 1", "Rejected", "Stuck 2"])
    #expect(failures.strikes(for: ids[0]) == 0)
    #expect(failures.strikes(for: ids[2]) == 0)
    try await expectCategory(writer, id: ids[1], uncategorizedLabel)
    try await expectPending(writer, id: ids[3])
  }

  nonisolated private static let retryAfterFailures: [any Error] = [
    VercelClassificationError.http(503, retryAfter: 30),
    OpenAIError.apiError(statusCode: 503, message: "x", retryAfter: 30),
  ]

  @Test(arguments: TransientEntrySkipTests.retryAfterFailures)
  func retryAfterStopsTheDrainWithoutAMark(_ failure: any Error) async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Second"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureErrors(failure, count: .max)
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider).runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.abortDisposition == .transient(retryAfter: 30))
    #expect(await provider.callCount == 1)
    #expect(failures == TransientEntryFailures())
    for id in ids { try await expectPending(writer, id: id) }
  }

  @Test
  func openAITimeoutForOneArticleSkipsOnlyThatArticle() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck", "Second", "Third"], firstID: 1001)
    let transport = ClassificationTransportRecorder(route: { body in
      body.contains("Stuck") ? .failure(URLError(.timedOut)) : .success(CloudProviderFixture.openAI.success)
    })
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = OpenAIClassificationProvider(
      apiKey: "fake-openai-key", model: "gpt-test", send: { try await transport.send($0) },
      sleep: { try await retryClock.sleep($0) })
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider).runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.completedCount == 2)
    let bodies = await transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    #expect(bodies.count == 4)
    #expect(bodies.filter { $0.contains("Stuck") }.count == 2)
    #expect(await retryClock.delays == [.seconds(2)])
    try await expectPending(writer, id: ids[0])
    try await expectCategory(writer, id: ids[1], "tech")
    try await expectCategory(writer, id: ids[2], "tech")
  }

  @Test
  func cancelAfterASkipKeepsEveryArticlePendingAndChangesNoCount() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck", "Second", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    await provider.configureDelay(.seconds(5))
    let recorder = SnapshotRecorder()
    let runner = makeRunner(writer, provider: provider, recorder: recorder)
    let batch = Task {
      var failures = TransientEntryFailures()
      let outcome = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
      return (outcome, failures)
    }
    try await waitUntil("next request starts") { await provider.requestedTitles.count == 2 }
    batch.cancel()
    let (outcome, failures) = await batch.value
    #expect(outcome.isCancelled)
    #expect(failures == TransientEntryFailures())
    for id in ids { try await expectPending(writer, id: id) }
    #expect(await recorder.snapshots.filter(\.ownsAbort).isEmpty)
  }

  nonisolated private static let stoppingFailures: [any Error] = [
    VercelClassificationError.http(401, retryAfter: nil),
    FakeClassificationFailure(batchAbort: .providerUnavailable),
    VercelClassificationError.http(429, retryAfter: nil),
    OpenAIError.apiError(statusCode: 503, message: "x", retryAfter: 5),
    AppleFMClassificationError.modelUnavailable,
  ]

  @Test(arguments: TransientEntrySkipTests.stoppingFailures)
  func stoppingFailureAfterASuccessGivesThatArticleNoStrike(_ failure: any Error) async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck", "Healthy", "Stopper", "Backlog"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    await provider.configureFailure(failure, forTitle: "Stopper")
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider).runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.abortDisposition == (failure as? any ClassificationFailure)?.retryDisposition)
    #expect(await provider.requestedTitles == ["Stuck", "Healthy", "Stopper"])
    #expect(failures.strikes(for: ids[0]) == 1)
    #expect(failures.strikes(for: ids[2]) == 0)
    #expect(!failures.sendsLast(ids[2]))
    try await expectPending(writer, id: ids[2])
    try await expectPending(writer, id: ids[3])
  }

  nonisolated private static let serviceLimits: [any Error] = [
    VercelClassificationError.http(429, retryAfter: nil),
    VercelClassificationError.http(402, retryAfter: nil),
    OpenAIError.apiError(statusCode: 429, message: "x", retryAfter: nil),
    AppleFMClassificationError.rateLimited(retryAfter: nil),
  ]

  @Test(arguments: TransientEntrySkipTests.serviceLimits)
  func serviceLimitWithoutRetryAfterStopsTheDrain(_ failure: any Error) async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Second"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureErrors(failure, count: .max)
    let recorder = SnapshotRecorder()
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider, recorder: recorder)
      .runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(await provider.callCount == 1)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [.rateLimited])
    #expect(failures == TransientEntryFailures())
    for id in ids { try await expectPending(writer, id: id) }
  }

  // MARK: - Apple Foundation Models failures

  @Test
  func unavailableModelStopsTheDrainUntilTheModelReturns() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Second", "Third", "Fourth", "Fifth"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureErrors(AppleFMClassificationError.modelUnavailable, count: 1, afterSuccesses: 2)
    let recorder = SnapshotRecorder()
    let runner = makeRunner(writer, provider: provider, recorder: recorder)
    var failures = TransientEntryFailures()
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    switch outcome {
    case .aborted(.poll, completed: 2): break
    default: Issue.record("Expected a poll abort after two completed entries, got \(outcome)")
    }
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [.providerUnavailable])
    #expect(await provider.callCount == 3)
    for id in ids[2...] { try await expectPending(writer, id: id) }
    #expect(failures == TransientEntryFailures())

    await provider.configureAvailability(false)
    _ = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(await provider.callCount == 3)

    await provider.configureAvailability(true)
    let recovered = await runner.runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(recovered.completedCount == 3)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [.providerUnavailable, .providerUnavailable, nil])
    for id in ids { try await expectCategory(writer, id: id, "tech") }
    #expect(failures == TransientEntryFailures())
  }

  @Test
  func contentFailureTakesTheFallbackAndTheDrainContinues() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Poison", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(AppleFMClassificationError.guardrailViolation, forTitle: "Poison")
    let recorder = SnapshotRecorder()
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider, recorder: recorder)
      .runOneBatch(cutoffDate: .distantPast, failures: &failures)
    #expect(outcome.completedCount == 3)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [nil])
    try await expectCategory(writer, id: ids[0], "tech")
    try await expectCategory(writer, id: ids[1], uncategorizedLabel)
    try await expectCategory(writer, id: ids[2], "tech")
    #expect(failures == TransientEntryFailures())
  }

  @Test
  func rateLimitStopsTheDrainWithTheResetWait() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["First", "Second", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureErrors(AppleFMClassificationError.rateLimited(retryAfter: 30), count: .max, afterSuccesses: 1)
    let recorder = SnapshotRecorder()
    var failures = TransientEntryFailures()
    let outcome = await makeRunner(writer, provider: provider, recorder: recorder)
      .runOneBatch(cutoffDate: .distantPast, failures: &failures)
    switch outcome {
    case .aborted(.transient(retryAfter: 30), completed: 1): break
    default: Issue.record("Expected a transient abort with a 30-second wait after one completed entry, got \(outcome)")
    }
    #expect(await provider.callCount == 2)
    #expect(await recorder.snapshots.filter(\.ownsAbort).map(\.abort) == [.rateLimited])
    try await expectCategory(writer, id: ids[0], "tech")
    for id in ids[1...] { try await expectPending(writer, id: id) }
    #expect(failures == TransientEntryFailures())
  }

  // MARK: - Engine

  @Test
  func loneStuckArticleTakesTheLoopBackoff() async throws {
    let writer = try await makeWriter()
    let stuck = try await persist(writer, ["Stuck"], firstID: 1001)[0]
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    let clock = ClassificationSleepRecorder(immediateDelays: 1)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("second loop wait reached") { await clock.delays.count == 2 }
    #expect(await clock.delays == [.seconds(10), .seconds(20)])
    #expect(await provider.callCount == 2)
    #expect(engine.lastAbort == .offline)
    #expect(engine.currentEntryFailures.sendsLast(stuck))
    #expect(engine.currentEntryFailures.strikes(for: stuck) == 0)
    try await expectPending(writer, id: stuck)
    engine.stopContinuousClassification()
  }

  @Test
  func stuckArticleNextToAHealthyOneTakesThePollThenTheBackoff() async throws {
    let writer = try await makeWriter()
    let ids = try await persist(writer, ["Stuck", "Healthy"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    let clock = ClassificationSleepRecorder(immediateDelays: 1)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("second loop wait reached") { await clock.delays.count == 2 }
    #expect(await clock.delays == [.seconds(2), .seconds(10)])
    #expect(await provider.requestedTitles == ["Stuck", "Healthy", "Stuck"])
    #expect(engine.currentEntryFailures.strikes(for: ids[0]) == 1)
    #expect(engine.lastAbort == .offline)
    try await expectCategory(writer, id: ids[1], "tech")
    engine.stopContinuousClassification()
  }

  @Test
  func oneShotsKeepTheStrikesAndBothResetsClearThem() async throws {
    let writer = try await makeWriter()
    let start = Date().addingTimeInterval(-3600)
    let stuck = try await persist(writer, ["Stuck"], firstID: 1001, newest: start)[0]
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    for run in 1...3 {
      try await persist(writer, ["Newer \(run)"], firstID: 2000 + run, newest: start.addingTimeInterval(60 * Double(run)))
      await engine.classifyUnclassified(writer: writer)
      #expect(engine.currentEntryFailures.strikes(for: stuck) == run)
    }
    await engine.reclassifyAll(writer: writer)
    #expect(await provider.requestedTitles.filter { $0 == "Stuck" }.count == 4)
    #expect(engine.currentEntryFailures.strikes(for: stuck) == 1)
    try await expectPending(writer, id: stuck)
    engine.configurationChanged(writer: writer)
    #expect(engine.currentEntryFailures == TransientEntryFailures())
    engine.stopContinuousClassification()
  }

  @Test
  func configurationChangeDuringASkippingDrainLeavesNoCount() async throws {
    let writer = try await makeWriter()
    try await persist(writer, ["Stuck", "Second", "Third"], firstID: 1001)
    let provider = FakeClassificationProvider()
    await provider.configureFailure(Self.timeout, forTitle: "Stuck")
    await provider.configureDelay(.seconds(5))
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("first drain sends the second article") { await provider.requestedTitles.count == 2 }
    engine.configurationChanged(writer: writer)
    try await waitUntil("replacement drain sends the second article") { await provider.requestedTitles.count == 4 }
    #expect(await provider.requestedTitles == ["Stuck", "Second", "Stuck", "Second"])
    #expect(engine.currentEntryFailures == TransientEntryFailures())
    engine.stopContinuousClassification()
  }
}
