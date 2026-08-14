import Foundation
import Testing

@testable import Feeder

// MARK: - ClassificationEngine integration tests
//
// These tests exercise `ClassificationEngine`'s orchestration: end-to-end
// classification of pending entries, cancellation of an in-flight batch,
// the one-shot-replaces-continuous-loop slot management, and the
// error-recovery branch inside `ClassificationRunner.runOneBatch`.
//
// The on-device Foundation Model / OpenAI providers are bypassed entirely:
// the engine is constructed with `init(providerFactoryOverride:)` so each
// batch resolves through a `FakeClassificationProvider`. That means no
// `UserDefaults` and no Keychain access in the test target — strictly
// cleaner than the per-suite-UserDefaults pattern `SyncEngineTests` uses,
// because classification's only external dependency is the provider itself.
//
// Why these four scenarios:
//   1. Pending classification → covers the happy path: every unclassified
//      entry that survives the cutoff is handed to the provider and the
//      returned category is persisted onto the entry.
//   2. Cancel mid-flight       → covers `Task.isCancelled` honoured between
//      iterations of the batch loop. Regression guard against future
//      refactors that drop the in-loop cancellation check.
//   3. Slot management         → covers the one-shot-replays-continuous-loop
//      path in `runReplacingContinuousLoop` — manual triggers cancel the
//      polling loop, run inline, then restart it. Tests the UUID-tagged
//      `runExclusively` slot, not just clobber semantics.
//   4. Error recovery          → covers the `catch` branch in `runOneBatch`:
//      one provider call throws, but the batch continues and remaining
//      entries still get classified.

@MainActor
@Suite("ClassificationEngine")
struct ClassificationEngineTests {
  // MARK: - Fixtures

  /// Default category set that satisfies `runOneBatch`'s
  /// "categories non-empty" early return. "tech" is the label the fake
  /// provider returns by default so happy-path tests don't need extra
  /// configuration.
  private static let categories: [(label: String, displayName: String, description: String)] = [
    ("tech", "Tech", "Technology news"),
    ("world", "World", "World news"),
  ]

  /// Build a freshly-isolated in-memory `DataWriter`, an attached engine,
  /// and the fake provider that backs the engine. Seeds the category
  /// taxonomy (tech, world, uncategorized) so `runOneBatch` clears the
  /// "no categories" early return.
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
    // Runner falls back to `uncategorizedLabel` on errors / low confidence,
    // and `applyClassification` filters labels against the known set. Without
    // the uncategorized row present, the error-recovery test would silently
    // collapse the fallback label.
    try await writer.addCategory(
      label: uncategorizedLabel,
      displayName: "Uncategorized",
      description: "Fallback bucket",
      sortOrder: Self.categories.count
    )
  }

  /// Seed `count` Feedbin entries through the production
  /// `persistEntries` path so the engine sees them exactly as it would in
  /// production. Returns the entry IDs in seed order.
  ///
  /// Entries are stamped with a current-day `published` value so they pass
  /// `articleCutoffDate()`'s `publishedAt >= cutoff` filter — the default
  /// `FeedbinFixtures.entry` uses 2025-06-15 which would fall outside the
  /// cutoff and skip classification entirely.
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
      // Default fake response is "tech" — `applyConfidenceGate` keeps it at
      // confidence 1.0, and the label survives the `validLabels` filter
      // because we seeded the "tech" category in `seedCategories`.
      #expect(snapshot?.primaryCategory == "tech")
    }
  }

  // MARK: - 2. Cancellation stops the in-flight batch

  @Test
  func cancelStopsProcessing() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 10)

    // 100 ms per call → 10 entries take ≥1 s end-to-end. Cancelling after a
    // single call has landed is far below that and gives the runner plenty
    // of time to honour the cancellation check before the next iteration.
    await provider.configureDelay(.milliseconds(100))

    engine.startContinuousClassification(writer: writer)

    // Gate on the **provider** call counter — proves the runner has entered
    // its batch loop and is awaiting inside `provider.classify(...)`. The
    // `isClassifying` MainActor flag is set asynchronously via the progress
    // reporter and races the first provider call.
    try await waitUntil("provider.callCount >= 1") {
      await provider.callCount >= 1
    }

    engine.stopContinuousClassification()

    // Give the cancellation a moment to propagate through the runner: the
    // current `classify` returns (the fake's `Task.sleep` exits on cancel),
    // `applyClassification` runs, then the for-loop's `Task.isCancelled`
    // check fires and breaks the batch. 200 ms covers that comfortably.
    try await Task.sleep(for: .milliseconds(200))

    let callCount = await provider.callCount
    #expect(callCount < 10, "Expected cancellation to stop the batch before all 10 entries; got \(callCount)")
  }

  // MARK: - 3. Slot management: one-shot replays continuous loop

  @Test
  func slotManagementPreventsOverlap() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)

    // Small delay keeps the continuous loop's first batch in flight long
    // enough for the manual trigger to land while the loop is awaiting a
    // provider call. Without the delay the loop would empty its queue
    // before the test thread gets a chance to call `classifyUnclassified`.
    await provider.configureDelay(.milliseconds(50))

    engine.startContinuousClassification(writer: writer)
    #expect(engine.isContinuousLoopActive == true)

    let initialTaskID = engine.currentClassificationTaskID
    #expect(initialTaskID != nil)

    // Wait for the continuous loop to enter the provider — proves the slot
    // is occupied and the loop's batch is actually running, not just queued.
    try await waitUntil("provider.callCount >= 1") {
      await provider.callCount >= 1
    }

    // Manual trigger fires while the continuous loop is mid-batch. The
    // engine must (a) cancel the loop, (b) run the one-shot inline,
    // (c) restart the loop because `isContinuousModeActive` was true when
    // `runReplacingContinuousLoop` recorded it. This is the path the
    // planning discussion called out — continuous-restart-after-one-shot,
    // not just UUID clobber.
    await engine.classifyUnclassified(writer: writer)

    // (c) Continuous loop restarted: flag is back to true and the slot
    // holds a freshly-generated UUID, not the one from before the one-shot.
    #expect(engine.isContinuousLoopActive == true)
    let restartedTaskID = engine.currentClassificationTaskID
    #expect(restartedTaskID != nil)
    #expect(restartedTaskID != initialTaskID, "Restarted continuous loop must occupy a new slot UUID")

    // (b) Manual task ran to completion — every seeded entry is classified.
    // If the one-shot had been clobbered by the loop's restart it would have
    // returned before classifying these.
    let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)
    #expect(snapshot?.isClassified == true)

    // Clean shutdown so the restarted continuous loop doesn't leak into
    // the next test's process state.
    engine.stopContinuousClassification()
  }

  // MARK: - 4. Mid-batch progress bumps drive the live-refresh signal

  /// `ContentView` listens to `batchProgressVersion` to refresh the middle
  /// pane while a classification batch is still running. Without a per-
  /// snapshot bump the article list only updates on the terminal
  /// `isClassifying` false-edge, so freshly-classified entries stay in
  /// their old category until the whole batch finishes. The bump fires on
  /// every non-terminal `apply(snapshot)` — the initial "starting"
  /// snapshot, every throttled progress tick, and the final mid-batch
  /// tick — but **not** on the terminal `.terminal` snapshot.
  @Test
  func batchProgressVersionBumpsDuringBatch() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 3)
    let baseline = engine.batchProgressVersion

    await engine.classifyUnclassified(writer: writer)

    // Engine is back to idle, so the terminal snapshot has already
    // landed. The counter must have advanced at least once during the
    // batch — proves the mid-flight signal is observable to
    // `ContentView`'s `.onChange`.
    let bumps = engine.batchProgressVersion - baseline
    #expect(bumps >= 1, "Expected at least one mid-batch bump; got \(bumps)")
    #expect(engine.isClassifying == false)
  }

  /// The terminal `.terminal` snapshot must not bump
  /// `batchProgressVersion` — the existing `isClassifying` false-edge
  /// path in `ContentView` already covers the post-batch refresh, and a
  /// double bump on the terminal edge would race the deferred-drain
  /// dwell timer. This test runs the engine with **zero** unclassified
  /// inputs: `runOneBatch` exits via the no-inputs early return, which
  /// emits only a single `.terminal` snapshot and never the
  /// `isClassifying: true` opening snapshot. The counter must stay put.
  @Test
  func batchProgressVersionDoesNotBumpOnTerminalOnly() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    // Deliberately seed no entries — `fetchUnclassifiedInputs` returns
    // an empty list, the runner emits `.terminal` immediately, and
    // there is no non-terminal snapshot to bump the counter.
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

    // Fail exactly the first classify call. The runner's `catch` branch
    // assigns `uncategorizedLabel` to that entry and proceeds; the remaining
    // four calls receive the default "tech" response and produce normal
    // classifications.
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
    // Entries are fetched in `createdAt`-descending order by
    // `fetchUnclassifiedInputs`, so the exact entry that hits the failure
    // depends on insertion ordering. The invariant the test cares about is
    // not "which entry failed" but "exactly one failed, the rest succeeded".
    #expect(uncategorizedCount == 1)
    #expect(techCount == entryIDs.count - 1)
  }

  // MARK: - 6. Live denominator: total grows as entries arrive mid-drain

  /// Regression pin for issue #124. While a classification drain runs,
  /// entries that `SyncEngine` persists mid-flight must push the reported
  /// denominator (`totalToClassify`) up at the next chunk boundary — the total
  /// must not stay frozen at the first snapshot's value (the "stuck at
  /// 1/200 while 1000 were fetched" bug). Driving the `ClassificationRunner`
  /// directly (not via the engine) exposes the full snapshot timeline,
  /// including the drain-end snapshot the engine's `apply()` would otherwise
  /// collapse into its terminal reset.
  @Test
  func denominatorGrowsAsEntriesArriveMidDrain() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)
    try await seedCategories(writer)
    try await seedEntries(writer, count: 3)

    let provider = FakeClassificationProvider()
    // A per-call delay keeps the first chunk in flight long enough for the
    // mid-drain insert to land before the chunk-boundary re-count.
    await provider.configureDelay(.milliseconds(80))

    let recorder = SnapshotRecorder()
    let runner = ClassificationRunner(
      writer: writer,
      providerFactory: { provider },
      reportProgress: { await recorder.record($0) }
    )

    // chunkSize 50 > the 3 seeded rows, so they drain in one chunk; the two
    // mid-drain inserts land in the second chunk fetched at the boundary.
    let drain = Task { await runner.runOneBatch(cutoffDate: .distantPast, chunkSize: 50) }

    // Once the first classify is in flight, persist two more unclassified
    // entries — exactly the SyncEngine-persists-mid-classification case (#124).
    try await waitUntil("provider.callCount >= 1") { await provider.callCount >= 1 }
    let extra = [
      try FeedbinFixtures.entry(id: 2001, title: "Late A"),
      try FeedbinFixtures.entry(id: 2002, title: "Late B"),
    ]
    _ = try await writer.persistEntries(extra, unreadIDs: Set([2001, 2002]))

    await drain.value

    // The provider saw all five entries in one continuous drain — the drain did
    // not stop at the initial three.
    #expect(await provider.callCount == 5)

    let snapshots = await recorder.snapshots
    let nonTerminal = snapshots.filter(\.isClassifying)
    #expect(!nonTerminal.isEmpty)

    // Denominator opens at the 3 seeded rows, is non-decreasing, and reaches
    // the grown total of 5 — proving the mid-drain inserts widened it.
    let totals = nonTerminal.map(\.totalToClassify)
    #expect(nonTerminal.first?.totalToClassify == 3)
    #expect(totals == totals.sorted())
    #expect(totals.last == 5)

    // classifiedCount never resets mid-drain: monotonically non-decreasing and
    // ending at the whole-drain total.
    let classified = nonTerminal.map(\.classifiedCount)
    #expect(classified == classified.sorted())
    #expect(classified.last == 5)

    // AC1: the final pre-terminal snapshot is X == Y == processedCount (5/5).
    #expect(nonTerminal.last?.totalToClassify == 5)
    #expect(nonTerminal.last?.classifiedCount == 5)

    // The terminal snapshot closes the batch.
    #expect(snapshots.last?.isClassifying == false)
  }

  // MARK: - 7. Abort path: deterministic provider failure persists nothing

  /// A `ClassificationFailure` with a non-nil `batchAbort` thrown on the
  /// very first entry must end the drain with ZERO persisted classifications —
  /// every entry stays `isClassified == false` for the next poll to retry,
  /// and the snapshot timeline still closes with the terminal snapshot.
  /// Drives the runner directly (pattern of test 6) so the timeline is
  /// observable.
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

    // The batch stopped at the first provider call — no further entries
    // were attempted, none were persisted.
    #expect(await provider.callCount == 1)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == false, "Aborted batch must not persist entry \(id)")
    }

    // The abort path closes the batch with an OWNING outcome snapshot so
    // the progress UI never hangs on a stale "Categorizing…" row and the
    // banner carries the mapped cause.
    let last = await recorder.snapshots.last
    #expect(last?.isClassifying == false)
    #expect(last?.ownsAbort == true)
    #expect(last?.abort == .modelRejected)
  }

  /// An abort mid-drain keeps the successes persisted before the failure and
  /// leaves the remainder untouched — partial progress survives, nothing is
  /// misclassified.
  @Test
  func abortingFailureMidDrainKeepsPriorSuccesses() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 5)

    // Succeed for the first two calls, abort on the third.
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

  /// A `ClassificationFailure` with `batchAbort == nil` keeps today's
  /// per-entry behavior: the failing entry persists as Uncategorized and the
  /// drain continues to the end.
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

  /// Recoverable-worst-case proof: `reclassifyAll` resets every category
  /// first, so an always-aborting provider (e.g. a bad model pick) must
  /// leave the corpus fully unclassified — never misclassified — and the
  /// next poll can recover it once the configuration is fixed.
  @Test
  func reclassifyAllWithAlwaysAbortingProviderLeavesEverythingUnclassified() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    let entryIDs = try await seedEntries(writer, count: 3)

    // First classify successfully so every entry holds a real category.
    await engine.classifyUnclassified(writer: writer)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == true)
      #expect(snapshot?.primaryCategory == "tech")
    }

    // Now every call aborts — the worst case for a bad model selection.
    await provider.configureErrors(
      FakeClassificationFailure(batchAbort: .modelRejected), count: Int.max)

    await engine.reclassifyAll(writer: writer)

    // Reset ran, the batch aborted on its first call (3 successes + 1 abort),
    // and nothing was misclassified: every entry awaits the next poll.
    #expect(await provider.callCount == entryIDs.count + 1)
    for id in entryIDs {
      let snapshot = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snapshot?.isClassified == false)
      #expect(snapshot?.primaryCategory != "tech", "Aborted reclassify must not persist a category")
    }
    #expect(engine.isClassifying == false)
  }

  // MARK: - 8. Abort visibility: lastAbort lifecycle

  /// An aborted batch surfaces its mapped cause on `lastAbort`; the next
  /// clean batch clears it. The fake's error window exhausts after the first
  /// batch, modelling "config fixed" — the per-batch provider factory would
  /// deliver a swapped provider through exactly the same path.
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

  /// Mid-batch snapshots never touch `lastAbort` — only owning terminals do.
  @Test
  func midBatchSnapshotsDoNotTouchLastAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 5)
    engine.applyPreviewState(lastAbort: .keyRejected)
    await provider.configureDelay(.milliseconds(80))

    engine.startContinuousClassification(writer: writer)
    // Two calls in: the opening snapshot and at least one throttled progress
    // tick have flowed through apply(_:) while the batch is still running.
    try await waitUntil("provider.callCount >= 2") { await provider.callCount >= 2 }
    #expect(engine.lastAbort == .keyRejected, "Mid-batch snapshots must not touch lastAbort")

    engine.stopContinuousClassification()
  }

  /// A zero-pending drain OWNS a nil outcome and clears a stale banner —
  /// da amendment A3 semantics: `lastAbort` is "the outcome of the most
  /// recent batch attempt", NOT "the configuration is broken". Pending
  /// entries can age out overnight via the keep-days window even while the
  /// config stays bad; the next arriving article re-trips the banner within
  /// one poll.
  @Test
  func zeroPendingDrainClearsStaleAbort() async throws {
    let (engine, writer, _) = try await makeEngineAndWriter()
    // No entries seeded — the drain takes the zero-pending early return.
    engine.applyPreviewState(lastAbort: .modelRejected)

    await engine.classifyUnclassified(writer: writer)

    #expect(engine.lastAbort == nil)
  }

  /// Cancellation PRESERVES the banner (da's flicker guard): both the
  /// cancelled batch's exit and the continuous loop's exit emit plain
  /// `.terminal`, which does not own the abort field — so Sync-Now /
  /// Reclassify replacing the loop mid-batch cannot clear-then-retrip.
  @Test
  func cancellationPreservesLastAbort() async throws {
    let (engine, writer, provider) = try await makeEngineAndWriter()
    try await seedEntries(writer, count: 10)
    engine.applyPreviewState(lastAbort: .offline)
    await provider.configureDelay(.milliseconds(100))

    engine.startContinuousClassification(writer: writer)
    try await waitUntil("provider.callCount >= 1") { await provider.callCount >= 1 }
    engine.stopContinuousClassification()
    try await Task.sleep(for: .milliseconds(300))

    #expect(engine.lastAbort == .offline, "Cancellation must not clear the banner")
  }

  /// A repeated identical outcome must not rewrite `lastAbort` — the
  /// equality guard stops @Observable same-value churn on the 2 s poll
  /// cadence (which would re-announce the banner to VoiceOver). Asserted
  /// via the DEBUG-only write counter, following the engine's existing
  /// test-introspection precedent.
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

  /// The `isAvailable` early return emits an OWNING `.providerUnavailable`
  /// outcome (da amendment A2) — this makes Apple FM unavailability visible
  /// too, and prevents a plain terminal from wrongly leaving a stale banner
  /// state unowned while the provider is unusable.
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
}

// MARK: - OpenAIError → ClassificationAbortReason mapping

/// Pins the batch-abort mapping from the round-2 design of issue #175:
/// provider-level failures abort with a user-facing cause (401 → key,
/// other 4xx → model, 429/5xx → provider, network → offline); per-entry
/// model-output defects return nil and keep the Uncategorized fallback.
/// A silent flip here would either reintroduce the mass-misclassification
/// hazard (abort → fallback) or stall the drain on harmless per-entry
/// defects (fallback → abort).
@Suite("OpenAIError batch-abort mapping")
struct OpenAIErrorBatchAbortMappingTests {
  @Test
  func unauthorizedMapsToKeyRejected() {
    #expect(OpenAIError.apiError(statusCode: 401, message: "x").batchAbort == .keyRejected)
  }

  @Test(arguments: [400, 403, 404, 422])
  func otherClientErrorsMapToModelRejected(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x").batchAbort == .modelRejected)
  }

  @Test(arguments: [429, 500, 503])
  func rateLimitAndServerErrorsMapToProviderUnavailable(statusCode: Int) {
    #expect(
      OpenAIError.apiError(statusCode: statusCode, message: "x").batchAbort
        == .providerUnavailable)
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
}

// MARK: - Abort reason copy lock

/// Locks the owner-approved banner literals and symbols: payload-free by
/// design, so these fixed strings are the entire user-visible surface of a
/// batch abort (raw API/response text structurally cannot reach the UI).
/// Fragment convention — no trailing periods — matches the SyncStatusView
/// labels.
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
