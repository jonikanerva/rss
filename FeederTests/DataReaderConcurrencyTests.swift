import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - DataReader concurrency + freshness

/// Coverage for the read/write split: `DataReader` reads the article list and
/// sidebar counts on a SECOND read-only `ModelContext` over the same container,
/// so those reads never queue behind a write on `DataWriter`.
///
/// Green strict-concurrency proves data-race freedom, NOT logical freshness —
/// these tests are what give the freshness assurance. The registered-object
/// cases use the fetch → mutate+commit → re-fetch form (not
/// insert-then-first-fetch, which hits SQLite fresh and proves nothing about
/// the cached/registered path).
///
/// The merge-blocking freshness cases are `fetchUnreadCountsSnapshot` bucket
/// re-attribution (it reads `primaryCategory` / `primaryFolder` off
/// possibly-registered objects) and — since issue #148 retired the
/// staleness-immunity contract — `fetchEntrySections`' row projection, which
/// reads volatile scalars (`isRead`, `title`, …) into `EntryRowDTO`
/// snapshots. The projection therefore carries both a membership-drop case
/// and a committed-value case (`rowDTOCarriesCommittedIsReadFlip`), plus the
/// compile-time field-set pin.
/// `.serialized` serialises the tests WITHIN this suite so they run one at a
/// time. Its job here is INTRA-suite ordering, not capping coordinators: the
/// heavyweight `sharedContainerProductionShapeStress` (hundreds of concurrent
/// read-during-write rounds) must run ALONE, not multiplied by sibling tests
/// racing their own containers, and the gated / event-ordering tests
/// (`readerNeverSeesUncommittedClassification`, `readerNotSeriallyDependentOnWriter`)
/// want deterministic in-suite ordering. It is NOT the cross-suite coordinator
/// cap: Swift Testing still runs different suites in parallel (Apple's docs:
/// "This trait doesn't affect the execution of a test relative to its peers or
/// to unrelated tests."), so the `make test` gate disables target-wide
/// parallelism (`-parallel-testing-enabled NO`, STACK.md §14) to hold concurrent
/// coordinators at one; `.serialized` also keeps single-suite Xcode (Cmd-U) runs
/// safe. The isolated 1+1 `sharedContainerProductionShapeStress` test (clean
/// under Thread Sanitizer) proves the production-shape topology is safe.
@Suite("DataReader concurrency + freshness", .serialized)
struct DataReaderConcurrencyTests {
  /// Writer + reader over ONE shared on-disk WAL container (production journal
  /// mode; an in-memory shared-cache store races under parallel load — see
  /// `DataWriterTestSupport.makeOnDiskContainer`), pre-seeded with a feed and a
  /// two-category taxonomy (`apple` under folder `tech`, root-level
  /// `world_news`). All writes go through `writer`; all list/unread reads
  /// through `reader`.
  private func makePair() async throws -> (DataWriter, DataReader) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple",
      sortOrder: 0, folderLabel: "tech")
    try await writer.addCategory(
      label: "world_news", displayName: "World News", description: "World",
      sortOrder: 1)
    return (writer, reader)
  }

  // MARK: - AC1: registered-object freshness

  /// `fetchUnreadCountsSnapshot` is the ONLY surface that reads volatile scalars
  /// (`primaryCategory` / `primaryFolder`) off possibly-registered objects, so
  /// this is the merge-blocking freshness test: after the writer reclassifies a
  /// row the reader already registered, the snapshot must re-bucket the count
  /// from the old category to the new one — not serve the stale registered value.
  @Test("Snapshot re-buckets a committed reclassify on an already-registered object")
  func snapshotRebucketsCommittedReclassify() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9101, title: "Reclassify me")
    _ = try await writer.persistEntries([entry], unreadIDs: [9101])
    try await writer.applyClassification(
      entryID: 9101,
      result: ClassificationResult(entryID: 9101, categoryLabel: "apple", confidence: 0.9))

    // (a) Register 9101 in the reader's context via a first snapshot; bucketed
    // under `apple`.
    let snap1 = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snap1.categoryCounts["apple"] == 1)
    #expect(snap1.categoryCounts["world_news"] == nil)

    // (b) Writer reclassifies the SAME row to root `world_news` and commits.
    try await writer.applyClassification(
      entryID: 9101,
      result: ClassificationResult(entryID: 9101, categoryLabel: "world_news", confidence: 0.9))

    // (c)+(d) Re-fetch: the count moved `apple` → `world_news`. A stale
    // registered object would leave the count stuck on `apple`.
    let snap2 = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snap2.categoryCounts["apple"] == nil)
    #expect(snap2.categoryCounts["world_news"] == 1)
  }

  /// Membership freshness for `fetchEntrySections`: a row leaving the unread
  /// set after a committed mark-read must disappear from the next fetch —
  /// membership + order are SQL-committed-truthful. (Value freshness of the
  /// row DTOs themselves is pinned separately by
  /// `rowDTOCarriesCommittedIsReadFlip`.)
  @Test("Reader drops a row from the unread list after a committed mark-read")
  func readerDropsRowAfterCommittedMarkRead() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9001, title: "Apple story")
    _ = try await writer.persistEntries([entry], unreadIDs: [9001])
    try await writer.applyClassification(
      entryID: 9001,
      result: ClassificationResult(entryID: 9001, categoryLabel: "apple", confidence: 0.9))

    // (a) Register entry 9001 in the reader's context via a first fetch.
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    #expect(first.allEntryIDs.count == 1)

    // (b) Writer marks the SAME row read and commits.
    try await writer.markEntriesRead(feedbinEntryIDs: [9001])

    // (c)+(d) Re-fetch drops it from the unread list — membership is committed-
    // truthful, not served from the stale registered object.
    let second = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    #expect(second.allEntryIDs.isEmpty)
  }

  // MARK: - AC: reader-never-writes structural guard

  /// The committed-truthful-membership guarantee holds ONLY because the reader
  /// has zero unsaved changes (a `ModelContext` includes pending changes in
  /// fetch results by default). This pins the invariant structurally: after
  /// reads on both surfaces, the reader's context must have no pending changes.
  @Test("Reader never writes — its context stays change-free after fetches")
  func readerNeverWrites() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9401, title: "No writes")
    _ = try await writer.persistEntries([entry], unreadIDs: [9401])
    try await writer.applyClassification(
      entryID: 9401,
      result: ClassificationResult(entryID: 9401, categoryLabel: "apple", confidence: 0.9))

    _ = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    _ = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)

    let hasPending = await reader.testHasPendingChanges
    #expect(hasPending == false)
  }

  // MARK: - AC5-part-2: fetchEntrySections DTO field-set pin (compile-time) + value freshness

  /// Issue #148 RETIRED the "no volatile scalar" staleness-immunity contract:
  /// rows are value snapshots of committed state (see `EntryRowDTO`'s doc).
  /// What remains pinned — at compile time, through the full memberwise
  /// initializers — is the DECLARED field set: adding a stored field to any
  /// of these DTOs changes its memberwise signature and BREAKS THIS TEST'S
  /// COMPILE, forcing the reviewer to (a) confirm the new field is projected
  /// only from a `propertiesToFetch`-listed column or the prefetched `feed`
  /// (`DataReader.projectEntryRow`'s review rule), and (b) extend the
  /// freshness-contract docs if the field is volatile. Reflection stays out
  /// per `STACK.md § 7`.
  @Test("fetchEntrySections DTOs match the declared field set (compile-time pin)")
  func fetchEntrySectionsDTOFieldSetPin() throws {
    // EntryRowDTO: the declared row snapshot — persistent identity, render
    // fields, the isRead snapshot, the grouping input, and the favicon pair.
    let context = ModelContext(try DataWriterTestSupport.makeInMemoryContainer())
    let minted = Entry(
      feedbinEntryID: 4001, title: "Pin", author: nil, url: "https://example.com/pin",
      content: nil, summary: nil, extractedContentURL: nil, publishedAt: .now, createdAt: .now)
    context.insert(minted)
    let day = Date(timeIntervalSince1970: 0)
    let row = EntryRowDTO(
      persistentID: minted.persistentModelID,
      feedbinEntryID: 4001,
      title: "Pin",
      formattedPublishedTime: "09.30",
      displayDomain: "example.com",
      excerpt: "Excerpt",
      isRead: false,
      publishedAt: day,
      feedFeedbinID: 1,
      feedInitial: "E"
    )
    // EntryListSection: id (ForEach identity) + label + the row snapshots.
    let section = EntryListSection(id: day, label: "Section", rows: [row])
    // EntryListFetchResult: sections + the pre-flattened aggregates + the
    // paging outputs (issue #151: effectiveLimit / hasMore / appendTriggerID
    // / isPrefixExtension — all derived from the SAME committed fetch, so
    // they add no extra staleness surface).
    let result = EntryListFetchResult(
      sections: [section], allEntryIDs: [row.persistentID],
      distinctFeedIDs: [1], renderedUnreadFeedbinEntryIDs: [4001],
      effectiveLimit: 100, hasMore: false, appendTriggerID: nil,
      isPrefixExtension: false)
    // EntryListPageRequest: the paging inputs (issue #151) — window size,
    // trigger margin, and the previous ids for the prefix-extension check.
    let paging = EntryListPageRequest(
      limit: 100, appendTriggerMargin: 20, previousVisibleIDs: [])
    // Behavioural anchor so the constructions above are not dead code.
    #expect(result.sections.first == section)
    #expect(result.allEntryIDs == [row.persistentID])
    #expect(row.id == row.persistentID)
    #expect(paging.limit == 100)
  }

  /// Value freshness for the row projection (issue #148): the DTO reads
  /// volatile scalars, so it must serve COMMITTED values on the
  /// registered-object path. The pinned-row case is the production shape —
  /// a selected row retained in the unread fetch by `pinnedFeedbinEntryID`
  /// after a committed mark-read flips it must refetch with
  /// `isRead == true`, not the stale registered `false`.
  @Test("Refetched row DTO carries a committed isRead flip (pinned-row path)")
  func rowDTOCarriesCommittedIsReadFlip() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9201, title: "Flip me")
    _ = try await writer.persistEntries([entry], unreadIDs: [9201])
    try await writer.applyClassification(
      entryID: 9201,
      result: ClassificationResult(entryID: 9201, categoryLabel: "apple", confidence: 0.9))

    // (a) Register the row via a first unread fetch — snapshot is unread.
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: 9201)
    #expect(first.sections.flatMap(\.rows).map(\.isRead) == [false])
    #expect(first.renderedUnreadFeedbinEntryIDs == [9201])

    // (b) Writer marks the SAME row read and commits.
    try await writer.markEntriesRead(feedbinEntryIDs: [9201])

    // (c) Re-fetch with the row pinned: membership retained by the pin, and
    // the DTO reflects the COMMITTED flip.
    let second = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: 9201)
    #expect(second.sections.flatMap(\.rows).map(\.isRead) == [true])
    #expect(second.renderedUnreadFeedbinEntryIDs.isEmpty)
  }

  // MARK: - Production-shape 1+1 stress (TSan evidence gate for the shared topology)

  /// Arch's evidence gate for shipping option (i): isolate "does the SHARED
  /// container behave at PRODUCTION concurrency (exactly ONE writer + ONE reader
  /// actor on ONE shared container)" from "the test target's dozens-of-
  /// coordinators parallelism". `make test-stress-tsan` runs ONLY this
  /// `.serialized` suite (`-only-testing:FeederTests/DataReaderConcurrencyTests`),
  /// so it is the sole suite in the process and `.serialized` runs this test on
  /// its own — the only concurrency is the 1+1. (A Swift Testing *per-test*
  /// `-only-testing` selector matches zero cases, so the suite is the runnable
  /// unit.) Run under THREAD SANITIZER — a TSan-clean, zero-exception pass over
  /// the high iteration count is the ship signal; a TSan race or a 1+1 exception
  /// means fall back to contingency (c).
  ///
  /// Workload (no artificial gate/sleep): the writer sustains INSERTS
  /// (`persistEntries`) AND UPDATES (`applyClassification` + `markEntriesRead`),
  /// while the reader sustains `fetchEntrySections` AND `fetchUnreadCountsSnapshot`
  /// (the `enumerate` streaming-cursor path — the specific coordinator worry),
  /// concurrently, over hundreds of interleaved rounds so overlap is near-certain.
  /// Assertions: (1) zero exceptions/crashes (reaching the end); (2) committed-
  /// consistent, NON-TORN — no empty-string category bucket ever appears
  /// (a torn `isClassified`-with-empty-category row would key on ""); (3)
  /// reader-minted IDs resolve via `model(for:)` on a C_app context throughout;
  /// (4) reads don't starve — the reader completes all rounds while writes are
  /// in flight.
  @Test("Shared container: sustained 1+1 read-during-write is clean (TSan gate)")
  func sharedContainerProductionShapeStress() async throws {
    // DEDICATED-GATE ONLY: this test drives hundreds of concurrent
    // read-during-write rounds (~100 s under Thread Sanitizer) — a heavyweight
    // stress that belongs in its own run, not the everyday `make test-all`. So it
    // self-skips (no-op) unless `FEEDER_RUN_STRESS=1`, which only `make
    // test-stress-tsan` sets — via `TEST_RUNNER_FEEDER_RUN_STRESS=1` (xcodebuild
    // strips the `TEST_RUNNER_` prefix; a plain variable on the xcodebuild process
    // does not reach the host) — together with Thread Sanitizer. (The everyday
    // gate also runs serially — `-parallel-testing-enabled NO`, STACK.md § 14 —
    // so nothing over-stresses Core Data there either.)
    guard ProcessInfo.processInfo.environment["FEEDER_RUN_STRESS"] == "1" else { return }

    // ONE shared container (C_app-style), on-disk WAL — writer AND reader on it.
    let container = try DataWriterTestSupport.makeOnDiskContainer()
    let storeURL = container.configurations.first?.url
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
    let reader = await DataReader.makeDetached(modelContainer: container)

    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple", sortOrder: 0)
    // Baseline classified rows so the reader materializes real Entries during writes.
    let baseline = (0..<50).compactMap { try? FeedbinFixtures.entry(id: 1000 + $0, title: "Base \($0)") }
    _ = try await writer.persistEntries(baseline, unreadIDs: Set(baseline.map(\.id)))
    for e in baseline {
      try await writer.applyClassification(
        entryID: e.id,
        result: ClassificationResult(entryID: e.id, categoryLabel: "apple", confidence: 0.9))
    }

    await withTaskGroup(of: Void.self) { group in
      // Writer: sustained inserts + updates (classify every new row; mark-read
      // periodically) — no gate/sleep.
      group.addTask {
        var nextID = 100_000
        for round in 0..<300 {
          let batch = (0..<10).compactMap {
            try? FeedbinFixtures.entry(id: nextID + $0, title: "W\($0)")
          }
          let ids = batch.map(\.id)
          nextID += 10
          _ = try? await writer.persistEntries(batch, unreadIDs: Set(ids))
          for id in ids {
            try? await writer.applyClassification(
              entryID: id,
              result: ClassificationResult(entryID: id, categoryLabel: "apple", confidence: 0.9))
          }
          if round.isMultiple(of: 5), let first = ids.first {
            try? await writer.markEntriesRead(feedbinEntryIDs: [first])
          }
        }
      }
      // Reader: sustained fetches; assert non-torn + cross-context ID resolution
      // on every round while writes are in flight.
      group.addTask {
        for _ in 0..<300 {
          let result = try? await reader.fetchEntrySections(
            category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
          let snap = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
          if let snap {
            #expect(snap.categoryCounts[""] == nil)  // never a torn empty-category row
          }
          if let id = result?.allEntryIDs.first {
            // A reader-minted ID resolves in a C_app context (production path).
            let resolved = await writer.testResolveEntry(id)
            #expect(resolved != nil)
          }
        }
      }
    }

    // Final consistency: committed rows present, non-torn, IDs resolvable.
    let finalSnap = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(finalSnap.categoryCounts[""] == nil)
    #expect((finalSnap.categoryCounts["apple"] ?? 0) >= 50)
    let finalList = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    if let id = finalList.allEntryIDs.first {
      #expect(await writer.testResolveEntry(id) != nil)
    }

    // Best-effort temp-store cleanup (OS reclaims the temp dir regardless).
    if let storeURL {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(
          at: storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + suffix))
      }
    }
  }

  // MARK: - ID-resolution gate (render/selection path)

  /// A `PersistentIdentifier` the reader mints MUST resolve to the same live
  /// `Entry` in the writer / MainActor context via `model(for:)` — the exact
  /// production `ContentView` selection / detail path
  /// (`modelContext.model(for: id)` on reader-returned IDs). Option (i) shares
  /// ONE container, so this holds trivially (one coordinator ⇒ interoperable
  /// IDs); a SEPARATE reader container was rejected precisely because its IDs do
  /// NOT resolve here (they crash). This test keeps that guarantee pinned.
  @Test("A reader-minted PersistentIdentifier resolves in the writer's context")
  func readerMintedIDResolvesInWriterContainer() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9601, title: "Cross-container")
    _ = try await writer.persistEntries([entry], unreadIDs: [9601])
    try await writer.applyClassification(
      entryID: 9601,
      result: ClassificationResult(entryID: 9601, categoryLabel: "apple", confidence: 0.9))

    // The reader's context mints the PersistentIdentifier.
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    let id = try #require(result.allEntryIDs.first)

    // It must resolve to the SAME Entry in the writer / MainActor context via
    // `model(for:)` — the production selection path.
    let resolvedFeedbinID = await writer.testResolveEntry(id)
    #expect(resolvedFeedbinID == 9601)
  }

  // MARK: - AC2: non-starvation (event-ordering, not wall-clock)

  /// Asserts the reader "is NOT serially dependent on an in-flight writer op"
  /// — via EVENT ORDERING, not a wall-clock/ms bound (a ms ceiling would be
  /// host-dependent and reintroduce flake). A long writer op (30 batch-saves)
  /// signals `started` after its FIRST batch (29 remain) and `finished` at the
  /// end; the reader fetch is issued only after `started`, and the ordering
  /// assertion is that the reader completed while the writer was STILL running
  /// (`finished` not yet fired). What this genuinely catches: a future
  /// regression that makes the read path serially dependent on writer
  /// completion (a stray `await writer.…` or shared lock creeping in) — then the
  /// reader could not finish before `finished`, and this fails. It does NOT
  /// (and cannot, under actor reentrancy) catch "reader moved back onto the
  /// writer's actor" — the ID-resolution / crash-return guards + the isolated
  /// stress test cover that. No cooperative-thread block (`Thread.sleep`) — that
  /// would starve the parallel async suite (`STACK.md § 7`).
  @Test("Reader is not serially dependent on an in-flight writer op")
  func readerNotSeriallyDependentOnWriter() async throws {
    let (writer, reader) = try await makePair()
    let baseline = try FeedbinFixtures.entry(id: 9201, title: "Baseline")
    _ = try await writer.persistEntries([baseline], unreadIDs: [9201])
    try await writer.applyClassification(
      entryID: 9201,
      result: ClassificationResult(entryID: 9201, categoryLabel: "apple", confidence: 0.9))

    let started = AtomicFlag()
    let finished = AtomicFlag()
    // In-flight writer op: 30 small batch-saves. Signals `started` after batch 0
    // (29 still to run) and `finished` at the end. Kept modest so the test is
    // fast and cannot hang/tip the parallel suite; the 29-batch margin after the
    // reader's single fetch is ample for the ORDERING assertion (host-
    // independent — a work-count margin, not a ms bound).
    let writeTask = Task {
      var nextID = 200_000
      for i in 0..<30 {
        let batch = (0..<3).compactMap {
          try? FeedbinFixtures.entry(id: nextID + $0, title: "W\($0)")
        }
        nextID += 3
        _ = try? await writer.persistEntries(batch, unreadIDs: Set(batch.map(\.id)))
        if i == 0 { started.set() }
      }
      finished.set()
    }

    // Issue the reader fetch only once the writer is started-and-still-running.
    while !started.isSet { try await Task.sleep(for: .milliseconds(1)) }
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)

    // ORDERING: the reader's single fetch completed while the writer's 30-batch
    // op was still running (29:1 work ratio makes this host-independent, not a
    // timing bound). A serially-dependent read path could not have returned yet.
    #expect(finished.isSet == false)
    #expect(result.allEntryIDs.count == 1)

    await writeTask.value
    #expect(finished.isSet == true)
  }

  // MARK: - AC2: committed-only / anti-torn

  @Test("Reader never sees an uncommitted classification, then sees it committed")
  func readerNeverSeesUncommittedClassification() async throws {
    let (writer, reader) = try await makePair()
    // Seed an UNCLASSIFIED unread entry, committed. It must not appear under
    // any category yet.
    let entry = try FeedbinFixtures.entry(id: 9301, title: "Uncommitted")
    _ = try await writer.persistEntries([entry], unreadIDs: [9301])

    let started = AtomicFlag()
    let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    // Apply the classification on the writer context but suspend BEFORE save().
    let writeTask = Task {
      try await writer.gatedReclassify(
        feedbinEntryID: 9301, category: "apple", folder: "tech",
        started: started, gate: gate)
    }
    while !started.isSet { try await Task.sleep(for: .milliseconds(1)) }

    // Mutation is applied on the writer's context but NOT saved → the reader's
    // context must not observe it (no dirty read — journal-mode-independent).
    // Never a torn "classified with empty category" row — the row is simply
    // absent from the eligible set until the commit lands.
    let mid = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    #expect(mid.allEntryIDs.isEmpty)

    // Release the gate → the writer commits.
    gateContinuation.yield()
    gateContinuation.finish()
    try await writeTask.value

    // Now committed → the reader sees the fully-classified row.
    let after = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast)
    #expect(after.allEntryIDs.count == 1)
  }
}
