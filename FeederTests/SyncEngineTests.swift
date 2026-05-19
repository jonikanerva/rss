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
@Suite("SyncEngine")
struct SyncEngineTests {
  // MARK: - Per-test isolation

  /// Per-test isolated `UserDefaults` instance. Built with a unique
  /// `suiteName` so reads/writes of `lastSyncDate` and `pendingReadIDsToSync`
  /// never touch `.standard` and therefore can't race
  /// `DataWriterBootstrapTests` (which asserts on the `lastSyncDate` key in
  /// the standard domain). Swift Testing's `.serialized` trait can only
  /// serialise within a single suite — it does not cross suite boundaries —
  /// so a shared lock would not have worked here. Injecting a private
  /// `UserDefaults` is the cleaner fix.
  private let defaults: UserDefaults
  private let suiteName: String

  init() {
    let id = "FeederTests.SyncEngine.\(UUID().uuidString)"
    self.suiteName = id
    // `init(suiteName:)` returns nil for reserved names ("standard",
    // "main", etc.). A random UUID never hits one of those, so the force
    // unwrap here is safe and surfaces an immediate test failure if Apple
    // changes that contract.
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    self.defaults = defaults
  }

  // MARK: - Builders

  /// Build a configured `SyncEngine` with an in-memory `DataWriter` and the
  /// supplied fake client already attached. The engine reads/writes its
  /// `lastSyncDate` and queued-read-IDs against the per-test `defaults`
  /// suite — never the standard domain.
  ///
  /// `writer.bootstrap()` is deliberately **not** called: this suite
  /// covers sync orchestration, not store initialization, and only needs
  /// `Feed` rows (populated via `syncFeeds`) for the entry-persisting
  /// path — not the seeded category/folder taxonomy. Bootstrap itself is
  /// covered by `DataWriterBootstrapTests`.
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
    // Hold the entry-page stream open long enough for the race-guard test
    // window. The delay sits between the `fetchEntryPagesCallCount` bump
    // and the first page yield, so the moment the counter flips to 1 we
    // know the stream's task has started and we have the full delay
    // window to fire `refetchHistory()` before `sync()` can complete.
    await client.setEntryPagesInitialDelay(.milliseconds(400))

    let (engine, _) = try await makeEngine(with: client)

    let syncHandle = Task { await engine.sync() }

    // Gate on the **client** call counter, not `engine.isSyncing`.
    // `isSyncing` flips to `true` long before `fetchAllEntryPages` is
    // entered — gating on the flag would race the actual stream start.
    try await waitUntil("fetchEntryPagesCallCount >= 1") {
      await client.fetchEntryPagesCallCount >= 1
    }

    engine.refetchHistory()

    // Let `refetchHistory`'s `backfillTask` run to completion. It should
    // observe `isSyncing == true` and bail out immediately without touching
    // the client. A 50 ms yield is plenty — the guarded path does no I/O.
    try await Task.sleep(for: .milliseconds(50))

    // Wait for the primary sync to finish naturally.
    await syncHandle.value

    let pagesAfter = await client.fetchEntryPagesCallCount
    #expect(pagesAfter == 1, "refetchHistory must not start a second entry-page fetch while sync() is running")
    #expect(engine.isSyncing == false)
  }

  // MARK: - 4. Mid-flight page bumps drive the live-refresh signal

  /// `ContentView` listens to `lastPersistedPageVersion` to refresh the
  /// middle pane while a sync is still in flight. Without a per-page bump
  /// the article list only updates on the terminal `isSyncing` false-edge,
  /// so entries persisted by earlier pages stay hidden until the whole
  /// sync finishes. This test drives the engine through a three-page
  /// response and asserts the counter advances once per persisted page.
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
    // Order inside a batch comes from `Set`'s `Array`-conversion; assert
    // by set equality so the test stays stable across Swift releases.
    #expect(Set(calls.first ?? []) == queuedIDs)
  }
}
