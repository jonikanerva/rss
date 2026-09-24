import Foundation
import Synchronization
import Testing

@testable import Feeder

// MARK: - ClassificationEngine integration tests
//
// The real providers are bypassed: the engine is built with a provider factory
// override, so every batch resolves through a fake. The test target therefore
// touches neither `UserDefaults` nor the Keychain.

@MainActor
@Suite("ClassificationEngine")
struct ClassificationEngineTests {
  // MARK: - Fixtures

  /// Default category set, which clears the "no categories" early return. The
  /// fake provider returns the first label by default, so a happy-path test
  /// needs no extra configuration.
  private static let categories: [(label: String, displayName: String, description: String)] = [
    ("tech", "Tech", "Technology news"),
    ("world", "World", "World news"),
  ]

  /// Build an isolated in-memory writer, the engine attached to it, and the
  /// fake provider behind that engine, with the category taxonomy seeded.
  private func makeEngineAndWriter() async throws -> (
    ClassificationEngine, DataWriter, FakeClassificationProvider
  ) {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)

    let provider = FakeClassificationProvider()
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    return (engine, writer, provider)
  }

  private func seedCategories(_ writer: DataWriter) async throws {
    for (index, category) in Self.categories.enumerated() {
      try await writer.addCategory(
        label: category.label,
        displayName: category.displayName,
        description: category.description,
        sortOrder: index
      )
    }
    // The runner falls back to the uncategorized label, and the writer filters
    // labels against the known set. Without that row seeded, the error-recovery
    // test would silently collapse its fallback.
    try await writer.addCategory(
      label: uncategorizedLabel,
      displayName: "Uncategorized",
      description: "Fallback bucket",
      sortOrder: Self.categories.count
    )
  }

  /// Seed entries through the production persist path, so the engine sees them
  /// as it would in production. Returns the entry IDs in seed order.
  ///
  /// Each entry carries a current-day timestamp, so it passes the retention
  /// cutoff; the fixture's own default date falls outside it and would skip
  /// classification entirely.
  @discardableResult
  private func seedEntries(_ writer: DataWriter, count: Int) async throws -> [Int] {
    let subscription = try FeedbinFixtures.subscription()
    try await writer.syncFeeds([subscription])

    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let nowIso = isoFormatter.string(from: Date())

    let ids = Array(1001..<(1001 + count))
    let entries = try ids.map { id in
      try FeedbinFixtures.entry(
        id: id,
        title: "Article \(id - 1001)",
        content: "<p>Body content for article \(id - 1001)</p>",
        published: nowIso
      )
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
    return ids
  }

  // MARK: - 1. Happy path: pending entries get classified

  @Test
  func runOnceClassifiesPendingEntries() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 4)

    await engine.classifyUnclassified(writer: writer)

    let callCount = await provider.callCount
    #expect(callCount == entryIDs.count)

    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot != nil)
      #expect(snapshot?.isClassified == true)
      // The fake's default response passes the confidence gate and survives the
      // valid-label filter, because the seed created that category.
      #expect(snapshot?.primaryCategory == "tech")
    }
  }

  // MARK: - 2. Cancellation stops the in-flight batch

  @Test
  func cancelStopsProcessing() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 10)

    // The per-call delay keeps the whole batch far longer than the point where
    // the test cancels, so the runner reaches its cancellation check with time
    // to spare.
    await provider.configureDelay(.milliseconds(100))

    engine.startContinuousClassification(writer: writer)

    // Gate on the provider call counter: it proves the runner is inside its
    // batch loop. The MainActor flag is set asynchronously and races the first
    // provider call.
    try await waitUntil("provider.callCount >= 1") {
      await provider.callCount >= 1
    }

    engine.stopContinuousClassification()

    // Let the cancellation propagate: the in-flight call returns, its result
    // persists, and the loop's cancellation check then breaks the batch.
    try await Task.sleep(for: .milliseconds(200))

    let callCount = await provider.callCount
    #expect(callCount < 10, "Expected cancellation to stop the batch before all 10 entries; got \(callCount)")
  }

  // MARK: - 3. Slot management: one-shot replays continuous loop

  @Test
  func slotManagementPreventsOverlap() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)

    // The delay keeps the loop's first batch in flight long enough for the
    // manual trigger to land while it awaits a provider call.
    await provider.configureDelay(.milliseconds(50))

    engine.startContinuousClassification(writer: writer)
    #expect(engine.isContinuousLoopActive == true)

    let initialTaskID = engine.currentClassificationTaskID
    #expect(initialTaskID != nil)

    // Wait until the loop is inside the provider, which proves the slot is
    // occupied and its batch is running rather than queued.
    try await waitUntil("provider.callCount >= 1") {
      await provider.callCount >= 1
    }

    // The manual trigger fires mid-batch. The engine must cancel the loop, run
    // the one-shot inline, and restart the loop, because continuous mode was
    // active when the replacement recorded it.
    await engine.classifyUnclassified(writer: writer)

    // The loop restarted: the flag is true again and the slot holds a fresh
    // UUID, not the one from before the one-shot.
    #expect(engine.isContinuousLoopActive == true)
    let restartedTaskID = engine.currentClassificationTaskID
    #expect(restartedTaskID != nil)
    #expect(restartedTaskID != initialTaskID, "Restarted continuous loop must occupy a new slot UUID")

    // The manual task ran to completion. A one-shot clobbered by the restart
    // would have returned before classifying these.
    let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)
    #expect(snapshot?.isClassified == true)

    // Shut down cleanly, so the restarted loop does not leak into the next
    // test's process state.
    engine.stopContinuousClassification()
  }

  // MARK: - 4. Mid-batch progress bumps drive the live-refresh signal

  /// The article list refreshes mid-batch from `batchProgressVersion`. Without
  /// a per-snapshot bump it would update only on the terminal edge, and a
  /// freshly classified entry would sit in its old category until the batch
  /// ended. Every non-terminal snapshot bumps; the terminal one does not.
  @Test
  func batchProgressVersionBumpsDuringBatch() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)
    let baseline = engine.batchProgressVersion

    await engine.classifyUnclassified(writer: writer)

    // The engine is idle again, so the terminal snapshot has landed. The
    // counter must have advanced during the batch, which is what makes the
    // mid-flight signal observable.
    let bumps = engine.batchProgressVersion - baseline
    #expect(bumps >= 1, "Expected at least one mid-batch bump; got \(bumps)")
    #expect(engine.isClassifying == false)
  }

  /// The terminal snapshot must not bump `batchProgressVersion`: the
  /// `isClassifying` false edge already covers the post-batch refresh, and a
  /// second bump would race the deferred drain. With no unclassified inputs the
  /// runner emits only that terminal snapshot, so the counter must stay put.
  @Test
  func batchProgressVersionDoesNotBumpOnTerminalOnly() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    // Seed no entries, so the runner emits the terminal snapshot at once and no
    // non-terminal snapshot can bump the counter.
    let baseline = engine.batchProgressVersion

    await engine.classifyUnclassified(writer: writer)

    #expect(engine.batchProgressVersion == baseline)
    #expect(engine.isClassifying == false)
  }

  // MARK: - 5. Error recovery: one failure does not poison the batch

  @Test
  func errorRecoveryContinuesWithNextBatch() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 5)

    // Fail the first classify call alone. The runner's catch branch assigns the
    // fallback to that entry and proceeds, and the rest classify normally.
    await provider.configureErrors(FakeProviderError(), count: 1)

    await engine.classifyUnclassified(writer: writer)

    let callCount = await provider.callCount
    #expect(callCount == entryIDs.count, "Batch must continue past a single failed call")

    var uncategorizedCount = 0
    var techCount = 0
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot != nil)
      #expect(snapshot?.isClassified == true, "Failed entry must still be marked classified — runner's contract")
      switch snapshot?.primaryCategory {
      case uncategorizedLabel: uncategorizedCount += 1
      case "tech": techCount += 1
      default:
        Issue.record("Unexpected category \(snapshot?.primaryCategory ?? "<nil>") for entry \(id)")
      }
    }
    // The fetch order decides which entry meets the failure, so the invariant
    // is that exactly one failed and the rest succeeded, not which one.
    #expect(uncategorizedCount == 1)
    #expect(techCount == entryIDs.count - 1)
  }

  // MARK: - 6. Live denominator: total grows as entries arrive mid-drain

  /// An entry persisted mid-drain must push the reported denominator up at the
  /// next chunk boundary; the total must not stay frozen at the first
  /// snapshot's value. Driving the runner directly exposes the whole snapshot
  /// timeline, including the drain-end snapshot the engine would collapse.
  @Test
  func denominatorGrowsAsEntriesArriveMidDrain() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)
    try await seedEntries(writer, count: 3)

    let provider = FakeClassificationProvider()
    // The per-call delay keeps the first chunk in flight long enough for the
    // mid-drain insert to land before the boundary re-count.
    await provider.configureDelay(.milliseconds(80))

    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: { provider },
      reportProgress: { await recorder.record($0) }
    )

    // The chunk size exceeds the seeded rows, so they drain in one chunk and the
    // mid-drain inserts land in the chunk fetched at the boundary.
    let drain = Task { await runner.runOneBatch(cutoffDate: .distantPast, chunkSize: 50) }

    // With the first classify in flight, persist more unclassified entries: the
    // sync-persists-mid-classification case.
    try await waitUntil("provider.callCount >= 1") { await provider.callCount >= 1 }
    let extra = [
      try FeedbinFixtures.entry(id: 2001, title: "Late A"),
      try FeedbinFixtures.entry(id: 2002, title: "Late B"),
    ]
    _ = try await writer.persistEntries(extra, unreadIDs: Set([2001, 2002]))

    _ = await drain.value

    // The provider saw every entry in one continuous drain, so the drain did not
    // stop at the seeded rows.
    #expect(await provider.callCount == 5)

    let snapshots = await recorder.snapshots
    let nonTerminal = snapshots.filter(\.isClassifying)
    #expect(!nonTerminal.isEmpty)

    // The denominator opens at the seeded rows, never decreases, and reaches the
    // grown total, which proves the mid-drain inserts widened it.
    let totals = nonTerminal.map(\.totalToClassify)
    #expect(nonTerminal.first?.totalToClassify == 3)
    #expect(totals == totals.sorted())
    #expect(totals.last == 5)

    // The classified count never resets mid-drain: it never decreases and ends
    // at the whole-drain total.
    let classified = nonTerminal.map(\.classifiedCount)
    #expect(classified == classified.sorted())
    #expect(classified.last == 5)

    // The final pre-terminal snapshot reports both numbers equal to the
    // processed count.
    #expect(nonTerminal.last?.totalToClassify == 5)
    #expect(nonTerminal.last?.classifiedCount == 5)

    // The terminal snapshot closes the batch.
    #expect(snapshots.last?.isClassifying == false)
  }

  // MARK: - 7. Abort path: deterministic provider failure persists nothing

  /// An aborting failure on the first entry must end the drain with nothing
  /// persisted: every entry stays unclassified for the next poll, and the
  /// timeline still closes with the terminal snapshot.
  @Test
  func abortingFailureOnFirstEntryPersistsNothing() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)
    let entryIDs = try await seedEntries(writer, count: 4)

    let provider = FakeClassificationProvider()
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .modelRejected), count: 1)

    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: { provider },
      reportProgress: { await recorder.record($0) }
    )
    await runner.runOneBatch(cutoffDate: .distantPast)

    // The batch stopped at the first provider call: no further entry was
    // attempted and none was persisted.
    #expect(await provider.callCount == 1)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == false, "Aborted batch must not persist entry \(id)")
    }

    // The abort path closes the batch with an owning outcome snapshot, so the
    // progress row never hangs and the banner carries the mapped cause.
    let last = await recorder.snapshots.last
    #expect(last?.isClassifying == false)
    #expect(last?.ownsAbort == true)
    #expect(last?.abort == .modelRejected)
  }

  /// An abort mid-drain keeps the successes persisted before the failure and
  /// leaves the remainder untouched: partial progress survives and nothing is
  /// misclassified.
  @Test
  func abortingFailureMidDrainKeepsPriorSuccesses() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 5)

    // Succeed for the first calls, then abort.
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .providerUnavailable), count: 1, afterSuccesses: 2
    )

    await engine.classifyUnclassified(writer: writer)

    #expect(await provider.callCount == 3, "Drain must stop at the aborting call")

    var classifiedCount = 0
    var unclassifiedCount = 0
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      if snapshot?.isClassified == true {
        #expect(snapshot?.primaryCategory == "tech")
        classifiedCount += 1
      } else {
        unclassifiedCount += 1
      }
    }
    #expect(classifiedCount == 2)
    #expect(unclassifiedCount == 3)
    #expect(engine.isClassifying == false)
  }

  /// A failure with no batch abort keeps the per-entry behaviour: the failing
  /// entry persists as uncategorized and the drain continues to the end.
  @Test
  func nonAbortingFailurePersistsUncategorizedAndContinues() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 3)
    await provider.configureErrors(FakeClassificationFailure(batchAbort: nil), count: 1)

    await engine.classifyUnclassified(writer: writer)

    #expect(await provider.callCount == entryIDs.count, "Non-aborting failure must not stop the drain")

    var uncategorizedCount = 0
    var techCount = 0
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == true)
      switch snapshot?.primaryCategory {
      case uncategorizedLabel: uncategorizedCount += 1
      case "tech": techCount += 1
      default:
        Issue.record("Unexpected category \(snapshot?.primaryCategory ?? "<nil>") for entry \(id)")
      }
    }
    #expect(uncategorizedCount == 1)
    #expect(techCount == entryIDs.count - 1)
  }

  /// A full reclassify resets every category first, so an always-aborting
  /// provider must leave the corpus unclassified and never misclassified. The
  /// next poll recovers it once the configuration is fixed.
  @Test
  func reclassifyAllWithAlwaysAbortingProviderLeavesEverythingUnclassified() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 3)

    // Classify successfully first, so every entry holds a real category.
    await engine.classifyUnclassified(writer: writer)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == true)
      #expect(snapshot?.primaryCategory == "tech")
    }

    // Now every call aborts: the worst case for a bad model selection.
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .modelRejected), count: Int.max)

    await engine.reclassifyAll(writer: writer)

    // The reset ran, the batch aborted on its first call, and nothing was
    // misclassified: every entry awaits the next poll.
    #expect(await provider.callCount == entryIDs.count + 1)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == false)
      #expect(snapshot?.primaryCategory != "tech", "Aborted reclassify must not persist a category")
    }
    #expect(engine.isClassifying == false)
  }

  // MARK: - 8. Abort visibility: lastAbort lifecycle

  /// An aborted batch surfaces its mapped cause, and the next clean batch clears
  /// it. The fake's error window closes after the first batch, which models a
  /// fixed configuration reaching the engine through the per-batch factory.
  @Test
  func abortedBatchSetsLastAbortAndCleanBatchClears() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .keyRejected), count: 1)

    await engine.classifyUnclassified(writer: writer)
    #expect(engine.lastAbort == .keyRejected)

    await engine.classifyUnclassified(writer: writer)
    #expect(engine.lastAbort == nil, "A clean drain must clear the banner")
  }

  /// Evidence of progress clears a stale banner mid-batch: after an abort, the
  /// resumed drain's first counting snapshot must clear it at once, not when
  /// the drain ends. Waiting on the count observes that snapshot itself,
  /// because one MainActor call sets the count and clears the banner.
  @Test
  func midBatchProgressClearsStaleAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 10)
    engine.applyPreviewState(lastAbort: .offline)
    await provider.configureDelay(.milliseconds(150))

    engine.startContinuousClassification(writer: writer)
    try await waitUntil("engine.classifiedCount > 0") {
      await engine.classifiedCount > 0
    }
    #expect(engine.lastAbort == nil, "First counting snapshot must clear the stale banner")

    engine.stopContinuousClassification()
  }

  /// A stale banner followed by a fully successful drain. The first counting
  /// snapshot clears the banner, and the drain end adds no second write: the
  /// final snapshot sees a cleared banner and skips, and the owning terminal is
  /// equality-suppressed. Exactly one write overall.
  @Test
  func resumedDrainClearsStaleAbortOnceAtFirstProgress() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 8)
    engine.applyPreviewState(lastAbort: .offline)
    await provider.configureDelay(.milliseconds(100))

    engine.startContinuousClassification(writer: writer)
    try await waitUntil("engine.classifiedCount > 0") {
      await engine.classifiedCount > 0
    }
    #expect(engine.lastAbort == nil, "First counting snapshot must clear the stale banner")

    // Let the drain complete: the engine returns to idle when the owning
    // terminal lands.
    try await waitUntil("engine.isClassifying == false") {
      await engine.isClassifying == false
    }
    #expect(engine.lastAbort == nil)
    #expect(
      engine.lastAbortWriteCount == 1,
      "Exactly one write: the evidence-of-progress clear; drain end adds none")

    engine.stopContinuousClassification()
  }

  /// A persistently failing retry loop never blinks the banner: every drain
  /// aborts before an entry completes, so the count stays at zero and the
  /// evidence-of-progress rule never fires. Zero writes overall, because the
  /// opening snapshots carry no evidence and the repeated same-value terminals
  /// are equality-suppressed.
  @Test
  func persistentlyFailingRetryPreservesLastAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)
    engine.applyPreviewState(lastAbort: .offline)
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .offline), count: Int.max)

    await engine.classifyUnclassified(writer: writer)
    await engine.classifyUnclassified(writer: writer)

    #expect(engine.lastAbort == .offline, "Failing retries must keep the banner up without blinking")
    #expect(engine.lastAbortWriteCount == 0, "No snapshot in a failing retry loop may write lastAbort")
  }

  /// A zero-pending drain owns a nil outcome and clears a stale banner, because
  /// `lastAbort` means "the outcome of the most recent batch attempt", not "the
  /// configuration is broken". Entries can age out of the retention window
  /// while the configuration stays bad, and the next article re-trips it.
  @Test
  func zeroPendingDrainClearsStaleAbort() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    // With no entries seeded the drain takes the zero-pending early return.
    engine.applyPreviewState(lastAbort: .modelRejected)

    await engine.classifyUnclassified(writer: writer)

    #expect(engine.lastAbort == nil)
  }

  /// Cancellation preserves the banner: the cancelled batch aborts with the same
  /// reason, so the outcome is equality-suppressed, its zero-count snapshots
  /// carry no evidence of progress, and the plain terminal does not own the
  /// field. Zero writes proves all three paths left the banner alone. The
  /// always-aborting provider is deliberate — a working one would race the
  /// throttled counting snapshot against the stop call.
  @Test
  func cancellationPreservesLastAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 10)
    engine.applyPreviewState(lastAbort: .offline)
    await provider.configureDelay(.milliseconds(100))
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .offline), count: Int.max)

    engine.startContinuousClassification(writer: writer)
    try await waitUntil("provider.callCount >= 1") { await provider.callCount >= 1 }
    engine.stopContinuousClassification()
    // Let the loop-exit terminal flow through before asserting: the point is
    // that it must not write.
    try await Task.sleep(for: .milliseconds(300))

    #expect(engine.lastAbort == .offline, "Cancellation must not clear the banner")
    #expect(engine.lastAbortWriteCount == 0, "No snapshot on the cancel path may write lastAbort")
  }

  /// A repeated identical outcome must not rewrite `lastAbort`: the equality
  /// guard stops same-value churn on the poll cadence, which would re-announce
  /// the banner to VoiceOver. Asserted through the debug-only write counter.
  @Test
  func repeatedSameAbortDoesNotRewriteLastAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 2)
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .providerUnavailable), count: Int.max)

    await engine.classifyUnclassified(writer: writer)
    #expect(engine.lastAbort == .providerUnavailable)
    #expect(engine.lastAbortWriteCount == 1)

    await engine.classifyUnclassified(writer: writer)
    #expect(engine.lastAbort == .providerUnavailable)
    #expect(engine.lastAbortWriteCount == 1, "Same-value outcome must not rewrite lastAbort")
  }

  /// The availability early return emits an owning provider-unavailable outcome,
  /// so an unusable on-device provider is visible too and no plain terminal
  /// leaves a stale banner unowned.
  @Test
  func unavailableProviderEmitsProviderUnavailableOutcome() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)
    try await seedEntries(writer, count: 2)

    let provider = FakeClassificationProvider()
    await provider.configureAvailability(false)

    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: { provider },
      reportProgress: { await recorder.record($0) }
    )
    await runner.runOneBatch(cutoffDate: .distantPast)

    #expect(await provider.callCount == 0)
    let last = await recorder.snapshots.last
    #expect(last?.isClassifying == false)
    #expect(last?.ownsAbort == true)
    #expect(last?.abort == .providerUnavailable)
  }

  // MARK: - 9. One provider per drain

  /// A chunk boundary must not build a new provider: the provider owns the
  /// cloud session of its drain.
  @Test
  func oneProviderServesTheWholeDrain() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)
    try await seedEntries(writer, count: 3)

    let provider = FakeClassificationProvider()
    let factoryCalls = Mutex(0)
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: {
        factoryCalls.withLock { $0 += 1 }
        return provider
      },
      reportProgress: { _ in }
    )
    let outcome = await runner.runOneBatch(cutoffDate: .distantPast, chunkSize: 2)

    #expect(outcome.completedCount == 3)
    #expect(factoryCalls.withLock { $0 } == 1)
    #expect(await provider.callCount == 3)
  }
}

// MARK: - OpenAIError → ClassificationAbortReason mapping

/// Pins the batch-abort mapping: a provider-level failure aborts with a
/// user-facing cause, and a per-entry model-output defect returns nil and keeps
/// the uncategorized fallback. A silent flip either reintroduces the
/// mass-misclassification hazard or stalls the drain on a harmless defect.
@Suite("OpenAIError batch-abort mapping")
struct OpenAIErrorBatchAbortMappingTests {
  @Test
  func unauthorizedMapsToKeyRejected() {
    #expect(
      OpenAIError.apiError(statusCode: 401, message: "x", retryAfter: nil).batchAbort
        == .keyRejected)
  }

  @Test(arguments: [400, 402, 403, 404, 422])
  func otherClientErrorsMapToModelRejected(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil).batchAbort
        == .modelRejected)
  }

  @Test
  func rateLimitMapsToRateLimited() {
    #expect(
      OpenAIError.apiError(statusCode: 429, message: "x", retryAfter: nil).batchAbort
        == .rateLimited)
  }

  @Test
  func requestTimeoutMapsToProviderUnavailable() {
    #expect(
      OpenAIError.apiError(statusCode: 408, message: "x", retryAfter: nil).batchAbort
        == .providerUnavailable)
  }

  @Test(arguments: [500, 502, 503, 599])
  func serverErrorsMapToProviderUnavailable(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil).batchAbort
        == .providerUnavailable)
  }

  @Test(arguments: [600, 700])
  func outOfRangeStatusesTakeThePerEntryFallback(statusCode: Int) {
    #expect(OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil).batchAbort == nil)
  }

  @Test
  func networkUnavailableMapsToOffline() {
    let error = OpenAIError.networkUnavailable(underlying: URLError(.notConnectedToInternet))
    #expect(error.batchAbort == .offline)
  }

  @Test
  func perEntryOutputDefectsDoNotAbort() {
    #expect(OpenAIError.emptyResponse.batchAbort == nil)
    #expect(OpenAIError.invalidResponse.batchAbort == nil)
  }

  @Test(
    arguments: [
      #"{"error":{"message":"too long","type":"invalid_request_error","code":"context_length_exceeded"}}"#,
      #"{"error":{"message":"too long","type":"invalid_request_error","code":"string_above_max_length"}}"#,
      #"{"error":{"message":"refused","type":"invalid_request_error","code":"content_policy_violation"}}"#,
      #"{"error":{"message":"refused","type":"invalid_prompt"}}"#,
    ])
  func perArticleRejectionsNeverAbortTheBatch(body: String) {
    let error = OpenAIClassificationProvider.makeAPIError(
      statusCode: 400, retryAfter: nil, body: body, now: Date(timeIntervalSince1970: 0))
    #expect(error.batchAbort == nil)
    #expect(error.retryDisposition == .poll)
  }

  @Test(
    arguments: [
      #"{"error":{"message":"bad model","type":"invalid_request_error","code":"model_not_found"}}"#,
      "",
      "not json at all",
    ])
  func unrecognizedBadRequestsStillAbortTheBatch(body: String) {
    let error = OpenAIClassificationProvider.makeAPIError(
      statusCode: 400, retryAfter: nil, body: body, now: Date(timeIntervalSince1970: 0))
    #expect(error.batchAbort == .modelRejected)
    #expect(error.retryDisposition == .blocked)
  }
}

// MARK: - OpenAIError → ClassificationRetry mapping

/// Pins the retry disposition: an OpenAI failure must wait as long as the same
/// failure from Vercel does. A `.poll` here would send one request every two
/// seconds for as long as the failure lasts.
@Suite("OpenAIError retry disposition")
struct OpenAIErrorRetryDispositionTests {
  @Test(arguments: [408, 429, 500, 502, 503, 599])
  func transientStatusesUseTheBoundedBackoff(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil).retryDisposition
        == .transient(retryAfter: nil))
  }

  @Test(arguments: [400, 401, 402, 403, 404, 407, 409, 422])
  func deterministicClientErrorsBlock(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil).retryDisposition
        == .blocked)
  }

  @Test
  func retryAfterHeaderReachesTheDisposition() {
    let now = Date(timeIntervalSince1970: 0)
    let bounded = OpenAIClassificationProvider.makeAPIError(statusCode: 429, retryAfter: "120", body: "x", now: now)
    #expect(bounded.retryDisposition == .transient(retryAfter: 120))
    let clamped = OpenAIClassificationProvider.makeAPIError(statusCode: 429, retryAfter: "7200", body: "x", now: now)
    #expect(clamped.retryDisposition == .transient(retryAfter: 3600))
  }

  @Test
  func transportFailureUsesBoundedBackoff() {
    let error = OpenAIError.networkUnavailable(underlying: URLError(.timedOut))
    #expect(error.retryDisposition == .transient(retryAfter: nil))
  }

  @Test
  func perEntryDefectsNeverReachTheRetryState() {
    for error in [OpenAIError.invalidResponse, .emptyResponse, .entryRejected(code: "x")] {
      #expect(error.batchAbort == nil)
      #expect(error.retryDisposition == .poll)
    }
  }
}

// MARK: - Shared disposition and abort-reason pairing

/// The banner contract in `STACK.md → Cloud classification`: a blocked
/// disposition must name a cause the Settings screen can fix, and a transient
/// disposition must name a self-healing cause. A mismatch either shows a dead
/// "Open Settings" button or hides the only recovery path the user has.
@Suite("Cloud failure disposition pairing")
struct CloudFailureDispositionPairingTests {
  private static let settingsFixable: [ClassificationAbortReason] = [
    .keyRejected, .modelRejected, .invalidResponse, .needsKey, .invalidCategories, .inputTooLarge,
  ]
  private static let selfHealing: [ClassificationAbortReason] = [
    .offline, .providerUnavailable, .rateLimited,
  ]

  private func expectPairing(_ failure: any ClassificationFailure) {
    guard let abort = failure.batchAbort else { return }
    switch failure.retryDisposition {
    case .blocked:
      #expect(Self.settingsFixable.contains(abort), "\(failure) blocks with \(abort)")
    case .transient:
      #expect(Self.selfHealing.contains(abort), "\(failure) backs off with \(abort)")
    case .poll:
      // A local re-check or a per-entry defect; no pairing obligation.
      break
    }
  }

  @Test(arguments: [
    199, 200, 300, 399, 400, 401, 402, 403, 404, 407, 408, 409, 422, 429, 499, 500, 502, 503, 599, 600, 700,
  ])
  func openAIHTTPFailuresPair(statusCode: Int) {
    expectPairing(OpenAIError.apiError(statusCode: statusCode, message: "x", retryAfter: nil))
  }

  @Test(arguments: [
    199, 200, 300, 399, 400, 401, 402, 403, 404, 407, 408, 409, 422, 429, 499, 500, 502, 503, 599, 600, 700,
  ])
  func vercelHTTPFailuresPair(statusCode: Int) {
    expectPairing(VercelClassificationError.http(statusCode, retryAfter: nil))
  }

  @Test
  func nonHTTPFailuresPair() {
    let openAI: [OpenAIError] = [
      .invalidResponse, .emptyResponse, .entryRejected(code: "context_length_exceeded"),
      .networkUnavailable(underlying: URLError(.notConnectedToInternet)),
    ]
    for failure in openAI { expectPairing(failure) }
    let vercel: [VercelClassificationError] = [
      .needsKey, .invalidCategories, .inputTooLarge, .invalidResponse, .network,
    ]
    for failure in vercel { expectPairing(failure) }
  }
}

// MARK: - Abort reason copy lock

/// Locks the banner literals and symbols. The abort reason is payload-free, so
/// these fixed strings are the entire user-visible surface of a batch abort.
@Suite("ClassificationAbortReason copy")
struct ClassificationAbortReasonCopyTests {
  @Test
  func displayLabelsMatchApprovedLiterals() {
    #expect(ClassificationAbortReason.modelRejected.displayLabel == "Model rejected the request")
    #expect(ClassificationAbortReason.keyRejected.displayLabel == "API key was rejected")
    #expect(ClassificationAbortReason.offline.displayLabel == "Categorizing paused — offline")
    #expect(
      ClassificationAbortReason.providerUnavailable.displayLabel
        == "Categorizing paused — provider unavailable")
    #expect(ClassificationAbortReason.needsKey.displayLabel == "Add an API key to start categorizing")
    #expect(
      ClassificationAbortReason.invalidCategories.displayLabel
        == "JEV needs unique category labels and at most 255 categories")
    #expect(ClassificationAbortReason.inputTooLarge.displayLabel == "Category definitions are too large for JEV")
    #expect(ClassificationAbortReason.invalidResponse.displayLabel == "JEV returned an invalid result")
    #expect(ClassificationAbortReason.rateLimited.displayLabel == "Categorizing paused — service limit reached")
  }

  @Test
  func symbolNamesMatchApprovedMapping() {
    #expect(ClassificationAbortReason.offline.symbolName == "wifi.slash")
    #expect(ClassificationAbortReason.modelRejected.symbolName == "exclamationmark.triangle")
    #expect(ClassificationAbortReason.keyRejected.symbolName == "exclamationmark.triangle")
    #expect(
      ClassificationAbortReason.providerUnavailable.symbolName == "exclamationmark.triangle")
  }
}
