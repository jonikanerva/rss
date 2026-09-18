import Foundation
import Testing

@testable import Feeder

// MARK: - SyncEngine integration tests
//
// These tests exercise the engine's orchestration — its state machine, error
// handling, and race guard — against a fake client. The HTTP, JSON and
// Link-header layer is a different test scope and is not covered here.

@MainActor
@Suite("SyncEngine")
struct SyncEngineTests {
  // MARK: - Per-test isolation

  /// Per-test isolated `UserDefaults`, under a unique suite name, so this
  /// suite's keys never touch the standard domain and cannot race a sibling
  /// suite that asserts on them. `.serialized` would not help: it orders tests
  /// within one suite only.
  private let defaults: UserDefaults
  private let suiteName: String

  init() {
    let id = "FeederTests.SyncEngine.\(UUID().uuidString)"
    self.suiteName = id
    // The initialiser returns nil only for a reserved name, and a random UUID is
    // never one, so the unwrap is safe and fails loudly if that changes.
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    self.defaults = defaults
  }

  // MARK: - Builders

  /// Build a configured engine over an in-memory writer with the fake client
  /// attached. Its stored keys live in the per-test suite, never the standard
  /// domain.
  ///
  /// It deliberately does not bootstrap the writer: this suite covers sync
  /// orchestration, and the entry-persisting path needs feed rows, not the
  /// seeded taxonomy.
  private func makeEngine(with client: FakeFeedbinClient) async throws -> (SyncEngine, DataWriter) {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)

    let engine = SyncEngine(defaults: defaults)
    engine.attachWriter(writer)
    engine.attachClient(client)
    return (engine, writer)
  }

  // MARK: - 1. Happy path

  @Test
  func successSyncFetchesAndPersistsEntries() async throws {
    let client = FakeFeedbinClient()
    let subscription = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    let entries = [
      try FeedbinFixtures.entry(id: 1001, feedId: 100),
      try FeedbinFixtures.entry(id: 1002, feedId: 100, title: "Second"),
    ]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage(entries)])
    await client.setUnreadIDsResponse(entries.map(\.id))

    let (engine, writer) = try await makeEngine(with: client)

    await engine.sync()

    let storedCount = try await writer.entryCount()
    #expect(storedCount == 2)
    #expect(engine.isSyncing == false)
    #expect(engine.lastSyncDate != nil)
    #expect(engine.lastError == nil)
    #expect(engine.lastSyncChangedEntryCount == 2)
  }

  // MARK: - 2. Auth-error path resets isSyncing

  @Test
  func authErrorResetsSyncingFlag() async throws {
    let client = FakeFeedbinClient()
    await client.setSubscriptionsError(FeedbinError.unauthorized)

    let (engine, _) = try await makeEngine(with: client)

    await engine.sync()

    #expect(engine.isSyncing == false)
    #expect(engine.lastError != nil)
    #expect(engine.lastSyncChangedEntryCount == 0)
  }

  // MARK: - 3. Race guard: refetchHistory bows out while sync is in-flight

  @Test
  func refetchHistoryGuardedFromOverlappingPrimary() async throws {
    let client = FakeFeedbinClient()
    let subscription = try FeedbinFixtures.subscription()
    let entries = [try FeedbinFixtures.entry()]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage(entries)])
    await client.setUnreadIDsResponse([])
    // Hold the entry-page stream open for the race-guard window. The delay sits
    // between the call-count bump and the first page yield, so once the counter
    // moves the stream has started and the whole delay is available.
    await client.setEntryPagesInitialDelay(.milliseconds(400))

    let (engine, _) = try await makeEngine(with: client)

    let syncHandle = Task { await engine.sync() }

    // Gate on the client call counter, not the engine flag: that flag turns true
    // long before the stream is entered.
    try await waitUntil("fetchEntryPagesCallCount >= 1") {
      await client.fetchEntryPagesCallCount >= 1
    }

    engine.refetchHistory()

    // Let the backfill task run to completion. It must observe the in-flight
    // sync and bail out without touching the client, and the guarded path does
    // no I/O.
    try await Task.sleep(for: .milliseconds(50))

    // Wait for the primary sync to finish on its own.
    await syncHandle.value

    let pagesAfter = await client.fetchEntryPagesCallCount
    #expect(pagesAfter == 1, "refetchHistory must not start a second entry-page fetch while sync() is running")
    #expect(engine.isSyncing == false)
  }

  // MARK: - 4. Mid-flight page bumps drive the live-refresh signal

  /// The article list refreshes mid-sync from `lastPersistedPageVersion`.
  /// Without a per-page bump it would update only on the terminal edge, and
  /// entries from earlier pages would stay hidden until the sync ended. The
  /// counter must advance once per persisted page.
  @Test
  func lastPersistedPageVersionBumpsPerPage() async throws {
    let client = FakeFeedbinClient()
    let subscription = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    let pages = [
      FeedbinFixtures.entriesPage([try FeedbinFixtures.entry(id: 2001)]),
      FeedbinFixtures.entriesPage([try FeedbinFixtures.entry(id: 2002, title: "Page 2")]),
      FeedbinFixtures.entriesPage([try FeedbinFixtures.entry(id: 2003, title: "Page 3")]),
    ]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse(pages)
    await client.setUnreadIDsResponse([2001, 2002, 2003])

    let (engine, _) = try await makeEngine(with: client)
    let baseline = engine.lastPersistedPageVersion

    await engine.sync()

    let bumps = engine.lastPersistedPageVersion - baseline
    #expect(bumps == pages.count, "Expected one bump per persisted page; got \(bumps)")
    #expect(engine.isSyncing == false)
  }

  // MARK: - 5. Queued read IDs are flushed during sync

  @Test
  func markReadFlushesIDsOnSync() async throws {
    let client = FakeFeedbinClient()
    let subscription = try FeedbinFixtures.subscription()
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage([])])
    await client.setUnreadIDsResponse([])

    let (engine, _) = try await makeEngine(with: client)

    let queuedIDs: Set<Int> = [1, 2, 3]
    engine.queueReadIDs(queuedIDs)

    await engine.sync()

    let calls = await client.deleteUnreadEntriesCallLog
    #expect(calls.count == 1, "Expected a single delete-unread batch flush")
    // The order inside a batch comes from the set's array conversion, so assert
    // by set equality and stay stable across Swift releases.
    #expect(Set(calls.first ?? []) == queuedIDs)
  }

  // MARK: - 6. Fetch total (B) is live mid-stream

  /// The fetch total must update in real time: the engine sets it un-throttled
  /// from each page's record count the instant that page lands, and only the
  /// numerator is throttled. This pins the behaviour, so a refactor cannot
  /// silently defer the total to the terminal edge.
  ///
  /// The fake holds the stream open between pages, so the assertion window sees
  /// the total while the sync is still running.
  @Test
  func fetchTotalIsLiveWhileStreamOpen() async throws {
    let client = FakeFeedbinClient()
    let subscription = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    // The record-count header is the query total and is the same on every page,
    // so both pages carry it even though each yields one row.
    let pages = [
      FeedbinFixtures.entriesPage([try FeedbinFixtures.entry(id: 5001)], totalCount: 1000),
      FeedbinFixtures.entriesPage(
        [try FeedbinFixtures.entry(id: 5002, title: "Page 2")], totalCount: 1000),
    ]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse(pages)
    await client.setUnreadIDsResponse([5001, 5002])
    await client.setEntryPagesInterPageDelay(.milliseconds(400))

    let (engine, _) = try await makeEngine(with: client)

    let syncHandle = Task { await engine.sync() }

    // Poll the engine until the total lands from the first page. The inter-page
    // delay keeps the stream open well past this cadence.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while engine.totalToFetch == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(engine.totalToFetch == 1000, "totalToFetch (B) must be live from page 1's record-count total")
    #expect(
      engine.isSyncing == true,
      "sync must still be in-flight while the inter-page delay holds the stream open")

    await syncHandle.value
    #expect(engine.isSyncing == false)
  }
}
