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
}
