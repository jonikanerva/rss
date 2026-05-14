import Foundation
import Testing

@testable import Feeder

// MARK: - SyncEngine integration tests
//
// These tests exercise `SyncEngine`'s orchestration logic — the
// state-machine, error handling, and race-guard behaviour — using a fake
// `FeedbinClientProtocol` implementation. The HTTP/JSON/Link-header layer
// owned by `FeedbinClient` is intentionally not covered here; that surface
// is a different test scope.
//
// Why these four scenarios:
//   1. Happy path  → verifies the engine fetches subscriptions, fetches
//                    entry pages, hands them to `DataWriter`, and resets
//                    its state on success.
//   2. Auth error  → verifies the `isSyncing = false` reset on the error
//                    branch (the bug PR 9 fixed). Without the `defer`/
//                    explicit reset the indicator would stick forever.
//   3. Race guard  → verifies that `refetchHistory()` declines to start a
//                    second entry-fetch pipeline while `sync()` is still
//                    in flight. This is the PR 9 fix point.
//   4. Mark-read   → verifies that queued read IDs are flushed via
//                    `deleteUnreadEntries` during a normal sync.

@MainActor
@Suite("SyncEngine", .serialized)
struct SyncEngineTests {
  /// Wipe `UserDefaults` keys this suite touches before each test. The
  /// `init` of a `@Suite` `struct` runs per test instance, giving us a free
  /// pre-test hook. The suite is `.serialized` so the wipe can't race
  /// another test in the same suite.
  init() {
    UserDefaults.standard.removeObject(forKey: lastSyncDateUserDefaultsKey)
    UserDefaults.standard.removeObject(forKey: "pendingReadIDsToSync")
  }

  // MARK: - Builders

  /// Build a configured `SyncEngine` with an in-memory `DataWriter` and the
  /// supplied fake client already attached.
  ///
  /// We deliberately do **not** call `writer.bootstrap(...)` — bootstrap
  /// writes to `UserDefaults.standard.feeder_schema_version`, which is
  /// shared with `DataWriterBootstrapTests`. Skipping bootstrap keeps this
  /// suite from racing the bootstrap suite. `SyncEngine`'s entry-persisting
  /// path only needs `Feed` rows (created via `syncFeeds`), not the seeded
  /// category/folder taxonomy.
  private func makeEngine(with client: FakeFeedbinClient) async throws -> (SyncEngine, DataWriter) {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container)

    let engine = SyncEngine()
    engine.attachWriter(writer)
    engine.attachClient(client)
    return (engine, writer)
  }

  // MARK: - 1. Happy path

  @Test
  func successSyncFetchesAndPersistsEntries() async throws {
    let client = FakeFeedbinClient()
    let subscription = try SyncEngineFixtures.subscription(id: 1, feedId: 100)
    let entries = [
      try SyncEngineFixtures.entry(id: 1001, feedId: 100),
      try SyncEngineFixtures.entry(id: 1002, feedId: 100, title: "Second"),
    ]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([SyncEngineFixtures.entriesPage(entries)])
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
    let subscription = try SyncEngineFixtures.subscription()
    let entries = [try SyncEngineFixtures.entry()]
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([SyncEngineFixtures.entriesPage(entries)])
    await client.setUnreadIDsResponse([])
    // Slow the page yield so the primary sync is still running when we
    // trigger `refetchHistory()`. 250 ms is comfortably above the actor-hop
    // noise floor without being slow enough to hurt test runtime.
    await client.setEntryPagesPerPageDelay(.milliseconds(250))

    let (engine, _) = try await makeEngine(with: client)

    let syncHandle = Task { await engine.sync() }

    // Wait until the primary sync has acquired the `isSyncing` flag. Without
    // this we'd race the guard check.
    try await waitUntil { engine.isSyncing }

    // Snapshot the call count before triggering the contended path.
    let pagesBefore = await client.fetchEntryPagesCallCount
    #expect(pagesBefore == 1, "Primary sync should have started its entry-page fetch")

    engine.refetchHistory()

    // Let the backfill task run to completion. It should observe
    // `isSyncing == true` and return immediately without touching the
    // client. A short yield + sleep is enough — the guarded path does no
    // I/O.
    try await Task.sleep(for: .milliseconds(50))

    // Now wait for the primary sync to finish naturally.
    await syncHandle.value

    let pagesAfter = await client.fetchEntryPagesCallCount
    #expect(pagesAfter == 1, "refetchHistory must not start a second entry-page fetch while sync() is running")
    #expect(engine.isSyncing == false)
  }

  // MARK: - 4. Queued read IDs are flushed during sync

  @Test
  func markReadFlushesIDsOnSync() async throws {
    let client = FakeFeedbinClient()
    let subscription = try SyncEngineFixtures.subscription()
    await client.setSubscriptionsResponse([subscription])
    await client.setEntryPagesResponse([SyncEngineFixtures.entriesPage([])])
    await client.setUnreadIDsResponse([])

    let (engine, _) = try await makeEngine(with: client)

    let queuedIDs: Set<Int> = [1, 2, 3]
    engine.queueReadIDs(queuedIDs)

    await engine.sync()

    let calls = await client.deleteUnreadEntriesCallLog
    #expect(calls.count == 1, "Expected a single delete-unread batch flush")
    // Order inside a batch is `Set.Array` conversion order; assert by set
    // equality so the test stays stable across Swift releases.
    #expect(Set(calls.first ?? []) == queuedIDs)
  }

  // MARK: - Helpers

  /// Spin-wait (yielding to the runtime) until `condition` becomes true or
  /// `timeout` elapses. Used to synchronise on `@MainActor`-driven state
  /// transitions without sprinkling fixed sleeps.
  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
      if ContinuousClock.now >= deadline {
        Issue.record("Timed out waiting for condition")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}
