import Foundation
import Testing

@testable import Feeder

@MainActor
@Suite("Classification cancellation and retry timelines")
struct ClassificationCancellationTests {
  private func fixture(entryCount: Int = 3) async throws -> DataWriter {
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

  private func cloudProvider(
    _ cloud: CloudProviderFixture, _ script: [Result<ClassificationHTTPResponse, URLError>], retryClock: ClassificationSleepRecorder
  ) -> (any ClassificationProvider, ClassificationTransportRecorder) {
    let transport = ClassificationTransportRecorder(script: script)
    let send: @Sendable (URLRequest) async throws -> ClassificationHTTPResponse = { try await transport.send($0) }
    let retrySleep: @Sendable (Duration) async throws -> Void = { try await retryClock.sleep($0) }
    let provider: any ClassificationProvider =
      switch cloud {
      case .vercel: VercelClassificationProvider(apiKey: "fake", send: send, sleep: retrySleep)
      case .openAI: OpenAIClassificationProvider(apiKey: "fake-openai-key", model: "gpt-test", send: send, sleep: retrySleep)
      }
    return (provider, transport)
  }

  private func runOneBatch(
    _ writer: DataWriter, provider: any ClassificationProvider
  ) async -> (ClassificationBatchOutcome, [ProgressSnapshot]) {
    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(writer: writer, providerFactory: { provider }, reportProgress: { await recorder.record($0) })
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast)
    return (outcome, await recorder.snapshots)
  }

  private func expectPending(_ writer: DataWriter, id: Int = 1001) async throws {
    let entry = try #require(await writer.fetchEntrySnapshot(feedbinEntryID: id))
    #expect(!entry.isClassified)
    #expect(entry.primaryCategory != uncategorizedLabel)
  }

  @Test
  func cancelledActorCallsCannotApplyOrResetAnyFields() async throws {
    let writer = try await fixture()
    for id in 1001...1003 {
      try await writer.applyClassification(entryID: id, result: .init(entryID: id, categoryLabel: "tech"))
    }
    var initial: [Int: EntrySnapshot] = [:]
    for id in 1001...1003 { initial[id] = try await writer.fetchEntrySnapshot(feedbinEntryID: id) }
    let apply = Task { @MainActor in
      try await writer.applyClassification(entryID: 1001, result: .init(entryID: 1001, categoryLabel: uncategorizedLabel))
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

  @Test(arguments: [false, true])
  func missingOpenAIKeyAbortsWithoutRequestsOrWrites(reclassifyAll: Bool) async throws {
    let writer = try await fixture()
    try await writer.applyClassification(entryID: 1001, result: .init(entryID: 1001, categoryLabel: "tech"))
    let transport = ClassificationTransportRecorder(data: Data())
    // Keep the real provider: this test pins the abort from its `validate(categories:)`.
    let provider = OpenAIClassificationProvider(apiKey: "", model: "gpt-test", send: { try await transport.send($0) })
    if reclassifyAll {
      let engine = ClassificationEngine(providerFactoryOverride: { provider })
      await engine.reclassifyAll(writer: writer)
      #expect(engine.lastAbort == .needsKey)
    } else {
      let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
      switch outcome {
      case .aborted(.poll, completed: 0): break
      default: Issue.record("Expected a poll abort with no completed entries, got \(outcome)")
      }
      #expect(snapshots.filter(\.ownsAbort).map(\.abort) == [.needsKey])
    }
    #expect(await transport.requests.isEmpty)
    #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)?.primaryCategory == "tech")
    for id in 1002...1003 { try await expectPending(writer, id: id) }
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
    let provider = VercelClassificationProvider(apiKey: "fake", send: { try await recorder.send($0) })
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
    let provider = VercelClassificationProvider(apiKey: "fake", send: { try await recorder.send($0) })
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    await engine.classifyUnclassified(writer: writer)
    #expect(await recorder.requests.count == 1)
    #expect(engine.lastAbort == .quotaExhausted)
    #expect(engine.lastAbortProvider != nil)
    #expect(VercelClassificationError.http(402, retryAfter: nil).retryDisposition == .blocked)
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
    // Each failed batch skips one article and stops at the second failure.
    await provider.configureErrors(VercelClassificationError.network, count: 14)
    let clock = ClassificationSleepRecorder(immediateDelays: 7)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("all retry delays recorded") { await clock.delays.count == 8 }
    let expected: [Duration] = [
      .seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(160), .seconds(300), .seconds(300), .seconds(2),
    ]
    #expect(await clock.delays == expected)
    #expect(await provider.callCount == 17)
    #expect(engine.lastAbort == nil)
    engine.stopContinuousClassification()
  }

  @Test
  func configurationChangeInterruptsBackoff() async throws {
    let writer = try await fixture()
    let provider = FakeClassificationProvider()
    await provider.configureErrors(VercelClassificationError.network, count: 2)
    let clock = ClassificationSleepRecorder()
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await clock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("backoff reached") { await clock.delays.count == 1 }
    #expect(await clock.delays == [.seconds(10)])
    #expect(await provider.callCount == 2)
    engine.configurationChanged(writer: writer)
    try await waitUntil("replacement completes") {
      let count = await provider.callCount
      let active = await engine.isClassifying
      return count == 5 && !active
    }
    #expect(engine.lastAbort == nil)
    engine.stopContinuousClassification()
  }

  // MARK: - Request retry

  nonisolated private static let healableFailures: [Result<ClassificationHTTPResponse, URLError>] = [
    .success(.status(503)), .success(.status(408)), .success(.status(429)),
    .failure(URLError(.timedOut)), .failure(URLError(.networkConnectionLost)),
  ]

  @Test(arguments: CloudProviderFixture.allCases, ClassificationCancellationTests.healableFailures)
  func healedRequestFailureClassifiesWithoutABanner(
    _ cloud: CloudProviderFixture, _ failure: Result<ClassificationHTTPResponse, URLError>
  ) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let loopClock = ClassificationSleepRecorder()
    let (provider, transport) = cloudProvider(cloud, [failure, .success(cloud.success)], retryClock: retryClock)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await loopClock.sleep($0) })
    await engine.classifyUnclassified(writer: writer)
    #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)?.primaryCategory == "tech")
    #expect(engine.lastAbort == nil)
    #expect(engine.lastAbortWriteCount == 0)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests.first?.httpBody == requests.last?.httpBody)
    #expect(await retryClock.delays == [.seconds(2)])
    #expect(await loopClock.delays.isEmpty)
  }

  @Test(arguments: ClassificationCancellationTests.healableFailures)
  func requestRetryReportsNoSnapshotBetweenAttempts(_ failure: Result<ClassificationHTTPResponse, URLError>) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, _) = cloudProvider(.vercel, [failure, .success(CloudProviderFixture.vercel.success)], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.completedCount == 1)
    #expect(snapshots.filter(\.ownsAbort).map(\.abort) == [nil])
    let stopsOnlyAtTheEnd = snapshots.dropLast().allSatisfy(\.isClassifying)
    #expect(stopsOnlyAtTheEnd)
  }

  @Test(arguments: CloudProviderFixture.allCases)
  func persistentServerErrorAbortsAfterThreeRequests(_ cloud: CloudProviderFixture) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(cloud, [.success(.status(503))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(snapshots.last?.ownsAbort == true)
    #expect(snapshots.last?.abort == .providerUnavailable)
    #expect(await transport.requests.count == 3)
    #expect(await retryClock.delays == [.seconds(2), .seconds(4)])
    try await expectPending(writer)
  }

  @Test(arguments: CloudProviderFixture.allCases)
  func lostConnectionOnEveryAttemptKeepsTheEntryPending(_ cloud: CloudProviderFixture) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(cloud, [.failure(URLError(.networkConnectionLost))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(snapshots.last?.abort == .offline)
    #expect(await transport.requests.count == 3)
    #expect(await retryClock.delays == [.seconds(2), .seconds(4)])
    try await expectPending(writer)
  }

  @Test(arguments: CloudProviderFixture.allCases)
  func repeatedTimeoutStopsAfterTwoRequests(_ cloud: CloudProviderFixture) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(cloud, [.failure(URLError(.timedOut))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(snapshots.last?.abort == .offline)
    #expect(await transport.requests.count == 2)
    #expect(await retryClock.delays == [.seconds(2)])
    try await expectPending(writer)
  }

  nonisolated private static let longRetryAfters: [(CloudProviderFixture, Int, Int)] = [
    (.vercel, 429, 120), (.vercel, 503, 30), (.openAI, 429, 120), (.openAI, 503, 30),
  ]

  @Test(arguments: ClassificationCancellationTests.longRetryAfters)
  func longRetryAfterStopsTheDrainAndSetsTheLoopWait(_ cloud: CloudProviderFixture, status: Int, retryAfter: Int) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let loopClock = ClassificationSleepRecorder()
    let (provider, transport) = cloudProvider(
      cloud, [.success(.status(status, retryAfter: String(retryAfter)))], retryClock: retryClock)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await loopClock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("loop wait reached") { await loopClock.delays.count == 1 }
    #expect(await loopClock.delays == [.seconds(retryAfter)])
    #expect(await transport.requests.count == 1)
    #expect(await retryClock.delays.isEmpty)
    let expectedAbort: ClassificationAbortReason = status == 429 ? .rateLimited : .providerUnavailable
    #expect(engine.lastAbort == expectedAbort)
    try await expectPending(writer)
    engine.stopContinuousClassification()
  }

  nonisolated private static let billingFailures: [(CloudProviderFixture, ClassificationHTTPResponse)] = [
    (.vercel, .status(402, retryAfter: "120", data: Data(VercelErrorBodies.budgetExceeded.utf8))),
    (.openAI, .status(429, retryAfter: "120", data: Data(OpenAIErrorBodies.billing[0].utf8))),
  ]

  @Test(arguments: ClassificationCancellationTests.billingFailures)
  func billingFailureWaitsForRetryOrTheHourlyRecheck(_ cloud: CloudProviderFixture, _ failure: ClassificationHTTPResponse) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let loopClock = ClassificationSleepRecorder()
    let (provider, transport) = cloudProvider(cloud, [.success(failure), .success(cloud.success)], retryClock: retryClock)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await loopClock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("loop wait reached") { await loopClock.delays.count == 1 }
    #expect(await loopClock.delays == [.seconds(3600)])
    #expect(await transport.requests.count == 1)
    #expect(await retryClock.delays.isEmpty)
    #expect(engine.lastAbort == .quotaExhausted)
    #expect(engine.lastAbortProvider != nil)
    try await expectPending(writer)
    await engine.classifyUnclassified(writer: writer)
    #expect(await transport.requests.count == 2)
    #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)?.primaryCategory == "tech")
    #expect(engine.lastAbort == nil)
    #expect(engine.lastAbortProvider == nil)
    engine.stopContinuousClassification()
  }

  @Test
  func serverErrorThenMalformedResultStopsWithoutAnotherRequest() async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(
      .vercel, [.success(.status(503)), .success(.status(200, data: Data("{}".utf8)))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == .blocked)
    #expect(snapshots.last?.abort == .invalidResponse)
    #expect(await transport.requests.count == 2)
    #expect(await retryClock.delays == [.seconds(2)])
    try await expectPending(writer)
  }

  @Test(arguments: CloudProviderFixture.allCases)
  func cancelledRetryWaitEndsTheBatchAsCancelled(_ cloud: CloudProviderFixture) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder()
    let (provider, transport) = cloudProvider(cloud, [.success(.status(503)), .success(cloud.success)], retryClock: retryClock)
    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(writer: writer, providerFactory: { provider }, reportProgress: { await recorder.record($0) })
    let batch = Task { await runner.runOneBatch(cutoffDate: .distantPast) }
    try await waitUntil("retry wait starts") { await retryClock.delays.count == 1 }
    batch.cancel()
    #expect(await batch.value.isCancelled)
    #expect(await transport.requests.count == 1)
    try await expectPending(writer)
    let snapshots = await recorder.snapshots
    #expect(snapshots.last?.isClassifying == false)
    let owningSnapshots = snapshots.filter(\.ownsAbort)
    #expect(owningSnapshots.isEmpty)
  }

  @Test
  func configurationChangeCancelsARetryWaitAtOnce() async throws {
    let writer = try await fixture()
    let retryClock = ClassificationSleepRecorder()
    let loopClock = ClassificationSleepRecorder()
    let (provider, transport) = cloudProvider(
      .vercel, [.success(.status(503)), .success(CloudProviderFixture.vercel.success)], retryClock: retryClock)
    let engine = ClassificationEngine(providerFactoryOverride: { provider }, sleep: { try await loopClock.sleep($0) })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("retry wait starts") { await retryClock.delays.count == 1 }
    let writes = engine.lastAbortWriteCount
    engine.configurationChanged(writer: writer)
    try await waitUntil("replacement drain completes") { await loopClock.delays.count == 1 }
    #expect(await loopClock.delays == [.seconds(2)])
    #expect(await retryClock.delays == [.seconds(2)])
    #expect(await transport.requests.count == 4)
    #expect(engine.lastAbort == nil)
    #expect(engine.lastAbortWriteCount == writes)
    for id in 1001...1003 { #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: id)?.primaryCategory == "tech") }
    engine.stopContinuousClassification()
  }

  nonisolated private static let nonHealableStatuses: [(CloudProviderFixture, Int, ClassificationAbortReason, ClassificationRetry)] = [
    (.vercel, 401, .keyRejected, .blocked),
    (.vercel, 402, .quotaExhausted, .blocked),
    (.vercel, 403, .keyRejected, .blocked),
    (.vercel, 400, .modelRejected, .blocked),
    (.openAI, 401, .keyRejected, .blocked),
    (.openAI, 402, .modelRejected, .blocked),
    (.openAI, 403, .modelRejected, .blocked),
    (.openAI, 400, .modelRejected, .blocked),
  ]

  @Test(arguments: ClassificationCancellationTests.nonHealableStatuses)
  func nonHealableStatusSendsOneRequest(
    _ cloud: CloudProviderFixture, status: Int, abort: ClassificationAbortReason, disposition: ClassificationRetry
  ) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(cloud, [.success(.status(status))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == disposition)
    #expect(snapshots.last?.abort == abort)
    #expect(await transport.requests.count == 1)
    #expect(await retryClock.delays.isEmpty)
    try await expectPending(writer)
  }

  @Test(arguments: CloudProviderFixture.allCases)
  func offlineTransportFailureSendsOneRequest(_ cloud: CloudProviderFixture) async throws {
    let writer = try await fixture(entryCount: 1)
    let retryClock = ClassificationSleepRecorder(immediateDelays: .max)
    let (provider, transport) = cloudProvider(cloud, [.failure(URLError(.notConnectedToInternet))], retryClock: retryClock)
    let (outcome, snapshots) = await runOneBatch(writer, provider: provider)
    #expect(outcome.abortDisposition == .transient(retryAfter: nil))
    #expect(snapshots.last?.abort == .offline)
    #expect(await transport.requests.count == 1)
    #expect(await retryClock.delays.isEmpty)
    try await expectPending(writer)
  }
}

enum CloudProviderFixture: CaseIterable, Sendable {
  case vercel
  case openAI

  var success: ClassificationHTTPResponse {
    let body =
      switch self {
      case .vercel: #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"tech":0.9,"uncategorized":0.1}}}}"#
      case .openAI: #"{"choices":[{"message":{"content":"{\"category\":\"tech\",\"confidence\":0.9}"}}]}"#
      }
    return .status(200, data: Data(body.utf8))
  }
}

extension ClassificationBatchOutcome {
  var abortDisposition: ClassificationRetry? {
    guard case .aborted(let retry, _) = self else { return nil }
    return retry
  }

  var completedCount: Int? {
    guard case .completed(let count) = self else { return nil }
    return count
  }

  var isCancelled: Bool {
    guard case .cancelled = self else { return false }
    return true
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
