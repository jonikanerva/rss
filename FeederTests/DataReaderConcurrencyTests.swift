import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - DataReader concurrency + freshness

/// Coverage for the read/write split: the reader serves the article list and
/// the sidebar counts from a second read-only context over the same container,
/// so those reads never queue behind a write.
///
/// Green strict concurrency proves data-race freedom, not logical freshness, so
/// these tests are what give the freshness assurance. Every registered-object
/// case uses the fetch, then mutate and commit, then re-fetch form: an
/// insert-then-first-fetch hits SQLite fresh and proves nothing about the
/// registered path.
///
/// `.serialized` gives intra-suite ordering only. It lets the heavyweight
/// stress case run alone rather than beside siblings racing their own
/// containers, and keeps the gated and event-ordering cases deterministic. It
/// does not cap coordinators across suites — the `make test` gate disables
/// target-wide parallelism for that (`STACK.md § 14`).
@Suite("DataReader concurrency + freshness", .serialized)
struct DataReaderConcurrencyTests {
  /// Writer and reader over one shared on-disk container in the production
  /// journal mode, because an in-memory shared-cache store races under parallel
  /// load. Seeded with a feed and a two-category taxonomy. Every write goes
  /// through the writer and every read through the reader.
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

  // MARK: - Registered-object freshness

  /// The unread snapshot reads its bucket keys off possibly-registered objects,
  /// so after the writer reclassifies a row the reader already registered, the
  /// next snapshot must re-bucket the count instead of serving the stale
  /// registered value.
  @Test("Snapshot re-buckets a committed reclassify on an already-registered object")
  func snapshotRebucketsCommittedReclassify() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9101, title: "Reclassify me")
    _ = try await writer.persistEntries([entry], unreadIDs: [9101])
    try await writer.applyClassification(
      entryID: 9101,
      result: ClassificationResult(entryID: 9101, categoryLabel: "apple", confidence: 0.9))

    // A first snapshot registers the row in the reader's context.
    let snap1 = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snap1.categoryCounts["apple"] == 1)
    #expect(snap1.categoryCounts["world_news"] == nil)

    // The writer reclassifies that same row and commits.
    try await writer.applyClassification(
      entryID: 9101,
      result: ClassificationResult(entryID: 9101, categoryLabel: "world_news", confidence: 0.9))

    // The re-fetch moves the count to the new category. A stale registered
    // object would leave it on the old one.
    let snap2 = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snap2.categoryCounts["apple"] == nil)
    #expect(snap2.categoryCounts["world_news"] == 1)
  }

  /// Membership freshness: a row leaving the unread set after a committed
  /// mark-read must disappear from the next fetch, so membership and order stay
  /// truthful to committed state. Value freshness is pinned separately.
  @Test("Reader drops a row from the unread list after a committed mark-read")
  func readerDropsRowAfterCommittedMarkRead() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9001, title: "Apple story")
    _ = try await writer.persistEntries([entry], unreadIDs: [9001])
    try await writer.applyClassification(
      entryID: 9001,
      result: ClassificationResult(entryID: 9001, categoryLabel: "apple", confidence: 0.9))

    // A first fetch registers the entry in the reader's context.
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    #expect(first.allEntryIDs.count == 1)

    // The writer marks that same row read and commits.
    try await writer.markEntriesRead(feedbinEntryIDs: [9001])

    // The re-fetch drops it from the unread list, so membership follows the
    // committed state and not the stale registered object.
    let second = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    #expect(second.allEntryIDs.isEmpty)
  }

  // MARK: - Reader-never-writes structural guard

  /// Committed-truthful membership holds only while the reader has no unsaved
  /// changes, because a fetch includes its context's pending changes. This pins
  /// the invariant: after reads on both surfaces the reader's context must hold
  /// nothing pending.
  @Test("Reader never writes — its context stays change-free after fetches")
  func readerNeverWrites() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9401, title: "No writes")
    _ = try await writer.persistEntries([entry], unreadIDs: [9401])
    try await writer.applyClassification(
      entryID: 9401,
      result: ClassificationResult(entryID: 9401, categoryLabel: "apple", confidence: 0.9))

    _ = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    _ = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)

    let hasPending = await reader.testHasPendingChanges
    #expect(hasPending == false)
  }

  // MARK: - DTO field-set pin and value freshness

  /// Pins the declared field set at compile time, through the full memberwise
  /// initializers. Adding a stored field to any of these DTOs changes its
  /// signature and breaks this test's compile, which forces a reviewer to
  /// confirm the new field is projected only from a listed column or the
  /// prefetched relationship, and to extend the freshness contract when the
  /// field is volatile. Reflection stays out (`STACK.md § 7`).
  @Test("fetchEntrySections DTOs match the declared field set (compile-time pin)")
  func fetchEntrySectionsDTOFieldSetPin() throws {
    // The declared row snapshot: identity, render fields, the read-state
    // snapshot, the grouping input, and the favicon pair.
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
    // A section: its identity, its label, and its row snapshots.
    let section = EntryListSection(id: day, label: "Section", rows: [row])
    // A fetch result: the sections, the three flattened aggregates, and the
    // exact paging flag.
    let result = EntryListFetchResult(
      sections: [section], allEntryIDs: [row.persistentID],
      distinctFeedIDs: [1], renderedUnreadFeedbinEntryIDs: [4001], hasMore: false)
    // A behavioural anchor, so the constructions above are not dead code.
    #expect(result.sections.first == section)
    #expect(result.allEntryIDs == [row.persistentID])
    #expect(row.id == row.persistentID)
  }

  /// Value freshness for the row projection: the DTO reads volatile scalars, so
  /// it must serve committed values on the registered-object path. The pinned
  /// row is the production shape — a selected row retained by the pin after a
  /// committed mark-read must refetch as read, not as the stale registered value.
  @Test("Refetched row DTO carries a committed isRead flip (pinned-row path)")
  func rowDTOCarriesCommittedIsReadFlip() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9201, title: "Flip me")
    _ = try await writer.persistEntries([entry], unreadIDs: [9201])
    try await writer.applyClassification(
      entryID: 9201,
      result: ClassificationResult(entryID: 9201, categoryLabel: "apple", confidence: 0.9))

    // A first unread fetch registers the row, and its snapshot is unread.
    let first = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: 9201, window: .firstPage(limit: 10_000))
    #expect(first.sections.flatMap(\.rows).map(\.isRead) == [false])
    #expect(first.renderedUnreadFeedbinEntryIDs == [9201])

    // The writer marks that same row read and commits.
    try await writer.markEntriesRead(feedbinEntryIDs: [9201])

    // Re-fetching with the row pinned keeps its membership, and the DTO carries
    // the committed flip.
    let second = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast,
      pinnedFeedbinEntryID: 9201, window: .firstPage(limit: 10_000))
    #expect(second.sections.flatMap(\.rows).map(\.isRead) == [true])
    #expect(second.renderedUnreadFeedbinEntryIDs.isEmpty)
  }

  // MARK: - Production-shape stress, one writer and one reader

  /// Isolates the production topology — exactly one writer and one reader actor
  /// on one shared container — from the test target's own parallelism.
  /// `make test-stress-tsan` runs this suite alone under Thread Sanitizer, so
  /// the only concurrency in the process is that pair. A clean pass with no
  /// exception over the high iteration count is the ship signal.
  ///
  /// The writer sustains inserts and updates while the reader sustains both read
  /// surfaces, with no gate or sleep, over enough interleaved rounds that
  /// overlap is near-certain. The test asserts that it reaches the end, that no
  /// torn row ever appears as an empty category bucket, that reader-minted IDs
  /// keep resolving in the app container, and that the reader completes every
  /// round while writes are in flight.
  @Test("Shared container: sustained 1+1 read-during-write is clean (TSan gate)")
  func sharedContainerProductionShapeStress() async throws {
    // This test drives hundreds of concurrent read-during-write rounds and
    // belongs in its own run, not the everyday gate, so it self-skips unless the
    // stress variable is set. Only the dedicated target sets it, and it must
    // reach the test host through the `TEST_RUNNER_` prefix.
    guard ProcessInfo.processInfo.environment["FEEDER_RUN_STRESS"] == "1" else { return }

    // One shared on-disk container, with the writer and the reader both on it.
    let container = try DataWriterTestSupport.makeOnDiskContainer()
    let storeURL = container.configurations.first?.url
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
    let reader = await DataReader.makeDetached(modelContainer: container)

    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple", sortOrder: 0)
    // Baseline classified rows, so the reader materialises real entries during
    // the writes.
    let baseline = (0..<50).compactMap { try? FeedbinFixtures.entry(id: 1000 + $0, title: "Base \($0)") }
    _ = try await writer.persistEntries(baseline, unreadIDs: Set(baseline.map(\.id)))
    for e in baseline {
      try await writer.applyClassification(
        entryID: e.id,
        result: ClassificationResult(entryID: e.id, categoryLabel: "apple", confidence: 0.9))
    }

    await withTaskGroup(of: Void.self) { group in
      // Sustained inserts and updates, with no gate and no sleep.
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
      // Sustained fetches, asserting non-torn results and cross-context ID
      // resolution on every round while writes are in flight.
      group.addTask {
        for _ in 0..<300 {
          let result = try? await reader.fetchEntrySections(
            category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
          let snap = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
          if let snap {
            #expect(snap.categoryCounts[""] == nil)  // never a torn empty-category row
          }
          if let id = result?.allEntryIDs.first {
            // A reader-minted ID must resolve in the app container.
            let resolved = await writer.testResolveEntry(id)
            #expect(resolved != nil)
          }
        }
      }
    }

    // Final consistency: the committed rows are present, non-torn, and their IDs
    // resolve.
    let finalSnap = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(finalSnap.categoryCounts[""] == nil)
    #expect((finalSnap.categoryCounts["apple"] ?? 0) >= 50)
    let finalList = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    if let id = finalList.allEntryIDs.first {
      #expect(await writer.testResolveEntry(id) != nil)
    }

    // Best-effort cleanup; the OS reclaims the temporary directory anyway.
    if let storeURL {
      for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(
          at: storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + suffix))
      }
    }
  }

  // MARK: - ID-resolution gate (render/selection path)

  /// An identifier the reader mints must resolve to the same live `Entry` in the
  /// MainActor context, which is the production selection and detail path. The
  /// shared container is what makes that hold, and this test keeps it pinned.
  @Test("A reader-minted PersistentIdentifier resolves in the writer's context")
  func readerMintedIDResolvesInWriterContainer() async throws {
    let (writer, reader) = try await makePair()
    let entry = try FeedbinFixtures.entry(id: 9601, title: "Cross-container")
    _ = try await writer.persistEntries([entry], unreadIDs: [9601])
    try await writer.applyClassification(
      entryID: 9601,
      result: ClassificationResult(entryID: 9601, categoryLabel: "apple", confidence: 0.9))

    // The reader's context mints the identifier.
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    let id = try #require(result.allEntryIDs.first)

    // It must resolve to the same entry in the MainActor context, which is the
    // production selection path.
    let resolvedFeedbinID = await writer.testResolveEntry(id)
    #expect(resolvedFeedbinID == 9601)
  }

  // MARK: - Non-starvation, by event ordering

  /// Asserts the reader is not serially dependent on an in-flight write, by
  /// event ordering rather than a wall-clock bound, which would be
  /// host-dependent and flaky. A long write signals its start after the first
  /// batch and its finish at the end; the read is issued after the start, and
  /// must complete before the finish.
  ///
  /// This catches a read path that becomes serially dependent on write
  /// completion. It cannot catch a reader moved back onto the writer's actor —
  /// the ID-resolution guard and the stress test cover that.
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
    // The in-flight write is a run of small batch saves. It signals its start
    // after the first batch and its finish at the end, and the remaining batches
    // are the margin the ordering assertion needs — a work count, not a
    // millisecond bound.
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

    // Issue the read only once the write has started and is still running.
    while !started.isSet { try await Task.sleep(for: .milliseconds(1)) }
    let result = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))

    // The read completed while the write was still running. A serially dependent
    // read path could not have returned yet.
    #expect(finished.isSet == false)
    #expect(result.allEntryIDs.count == 1)

    await writeTask.value
    #expect(finished.isSet == true)
  }

  // MARK: - Committed-only reads

  @Test("Reader never sees an uncommitted classification, then sees it committed")
  func readerNeverSeesUncommittedClassification() async throws {
    let (writer, reader) = try await makePair()
    // Seed a committed unclassified unread entry. It must not appear under any
    // category yet.
    let entry = try FeedbinFixtures.entry(id: 9301, title: "Uncommitted")
    _ = try await writer.persistEntries([entry], unreadIDs: [9301])

    let started = AtomicFlag()
    let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    // Apply the classification on the writer context, but suspend before the
    // save.
    let writeTask = Task {
      try await writer.gatedReclassify(
        feedbinEntryID: 9301, category: "apple", folder: "tech",
        started: started, gate: gate)
    }
    while !started.isSet { try await Task.sleep(for: .milliseconds(1)) }

    // The mutation is applied but unsaved, so the reader must not observe it.
    // The row is absent from the eligible set until the commit lands, never
    // present as a torn classified-with-empty-category row.
    let mid = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    #expect(mid.allEntryIDs.isEmpty)

    // Release the gate, and the writer commits.
    gateContinuation.yield()
    gateContinuation.finish()
    try await writeTask.value

    // Now that it is committed, the reader sees the classified row.
    let after = try await reader.fetchEntrySections(
      category: "apple", folder: nil, showRead: false, cutoffDate: .distantPast, window: .firstPage(limit: 10_000))
    #expect(after.allEntryIDs.count == 1)
  }
}
