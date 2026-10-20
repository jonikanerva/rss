import Foundation
import Testing

@testable import Feeder

// MARK: - Cursor rule

@Suite("Entry coverage cursor rule")
struct EntryCoverageCursorRuleTests {
  private static let cutoff = Date(timeIntervalSince1970: 1_800_000_000)

  @Test
  func noCursorCoversTheFullWindow() {
    #expect(EntryCoverageCursor.since(after: nil, cutoff: Self.cutoff) == Self.cutoff)
  }

  @Test
  func sinceStartsTheOverlapBeforeTheNewestCoveredEntry() {
    let newest = Self.cutoff.addingTimeInterval(3600)
    let since = EntryCoverageCursor.since(after: EntryCoverageCursor(newestCreatedAt: newest), cutoff: Self.cutoff)
    #expect(since == newest.addingTimeInterval(-EntryCoverageCursor.overlap))
  }

  @Test
  func sinceNeverReachesBehindTheCutoff() {
    let cursor = EntryCoverageCursor(newestCreatedAt: Self.cutoff.addingTimeInterval(60))
    #expect(EntryCoverageCursor.since(after: cursor, cutoff: Self.cutoff) == Self.cutoff)
  }

  @Test
  func emptyFetchKeepsTheCursor() {
    let cursor = EntryCoverageCursor(newestCreatedAt: Self.cutoff)
    #expect(EntryCoverageCursor.advanced(cursor, by: nil) == cursor)
    #expect(EntryCoverageCursor.advanced(nil, by: nil) == nil)
  }

  @Test
  func cursorNeverMovesBack() {
    let cursor = EntryCoverageCursor(newestCreatedAt: Self.cutoff)
    let older = Self.cutoff.addingTimeInterval(-60)
    let newer = Self.cutoff.addingTimeInterval(60)
    #expect(EntryCoverageCursor.advanced(cursor, by: older) == cursor)
    #expect(EntryCoverageCursor.advanced(cursor, by: newer)?.newestCreatedAt == newer)
    #expect(EntryCoverageCursor.advanced(nil, by: older)?.newestCreatedAt == older)
  }
}

// MARK: - Sync engine coverage

/// The fake client models the Feedbin `since` filter on `created_at`.
/// Timestamps sit one hour before the real clock, inside the retention window
/// that `queryCutoffDate` computes from the real clock (`STACK.md § 10`).
@MainActor
@Suite("Entry coverage cursor sync")
struct EntryCoverageCursorSyncTests {
  private struct PageFailure: Error {}

  private let isolatedDefaults: IsolatedDefaults
  private var defaults: UserDefaults { isolatedDefaults.defaults }
  private let serverBase = Date().addingTimeInterval(-3600)

  init() throws {
    isolatedDefaults = try IsolatedDefaults("EntryCoverageCursor")
  }

  /// `clock` holds the Mac time that `lastSyncDate` records.
  private func makeEngine(
    with client: FakeFeedbinClient, clock: MacClock
  ) async throws -> (SyncEngine, DataWriter) {
    let writer = try await DataWriterTestSupport.makeWriter()
    let engine = SyncEngine(
      defaults: defaults, credentialStore: MemoryFeedbinCredentialStore(), account: .unused,
      now: { clock.now })
    engine.attachWriter(writer)
    engine.attachClient(client)
    await client.setSubscriptionsResponse([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    return (engine, writer)
  }

  private func entry(_ id: Int, createdAfterBase offset: TimeInterval) throws -> FeedbinEntry {
    let created = formatDateForFeedbin(serverBase.addingTimeInterval(offset))
    return try FeedbinFixtures.entry(id: id, feedId: 100, published: created, createdAt: created)
  }

  private static func sinceLog(_ client: FakeFeedbinClient) async -> [Date?] {
    await client.fetchEntryPagesSinceLog
  }

  @Test
  func entryCreatedBeforeTheLocalCompletionIsFetchedInTheNextCycle() async throws {
    let client = FakeFeedbinClient()
    let first = try entry(1, createdAfterBase: 0)
    await client.setServerEntries([first])
    let clock = MacClock(serverBase.addingTimeInterval(120))
    let (engine, writer) = try await makeEngine(with: client, clock: clock)
    await engine.sync()

    let createdDuringSync = try entry(2, createdAfterBase: 30)
    await client.setServerEntries([first, createdDuringSync])
    await engine.sync()

    #expect(try await writer.entryCount() == 2)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == createdDuringSync.createdAt)
    let sinceLog = await Self.sinceLog(client)
    #expect(sinceLog.last == first.createdAt.addingTimeInterval(-EntryCoverageCursor.overlap))
  }

  @Test
  func equalTimestampsSurviveTheBoundaryAndRepeatsDoNotDuplicate() async throws {
    let client = FakeFeedbinClient()
    let visibleFirst = try entry(1, createdAfterBase: 0)
    let visibleLater = try entry(2, createdAfterBase: 0)
    await client.setServerEntries([visibleFirst])
    let (engine, writer) = try await makeEngine(with: client, clock: MacClock(serverBase))
    await engine.sync()

    await client.setServerEntries([visibleFirst, visibleLater])
    await engine.sync()
    #expect(try await writer.entryCount() == 2)
    #expect(engine.lastSyncChangedEntryCount == 1)

    await engine.sync()
    #expect(try await writer.entryCount() == 2)
    #expect(engine.lastSyncChangedEntryCount == 0)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == visibleFirst.createdAt)
  }

  @Test
  func failedPageAdvancesNeitherTheCursorNorTheLastSyncDate() async throws {
    let client = FakeFeedbinClient()
    let covered = try entry(1, createdAfterBase: 0)
    await client.setServerEntries([covered])
    let clock = MacClock(serverBase)
    let (engine, _) = try await makeEngine(with: client, clock: clock)
    await engine.sync()
    let firstSyncDate = engine.lastSyncDate

    await client.setServerEntries(nil)
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage([try entry(2, createdAfterBase: 300)])])
    await client.setEntryPagesError(PageFailure())
    clock.now = serverBase.addingTimeInterval(600)
    await engine.sync()

    #expect(engine.lastError != nil)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == covered.createdAt)
    #expect(engine.lastSyncDate == firstSyncDate)

    await client.setEntryPagesError(nil)
    await engine.sync()
    let sinceLog = await Self.sinceLog(client)
    #expect(sinceLog.last == covered.createdAt.addingTimeInterval(-EntryCoverageCursor.overlap))
  }

  @Test
  func cancelledSyncAdvancesNeitherTheCursorNorTheLastSyncDate() async throws {
    let client = FakeFeedbinClient()
    let covered = try entry(1, createdAfterBase: 0)
    await client.setServerEntries([covered])
    let clock = MacClock(serverBase)
    let (engine, writer) = try await makeEngine(with: client, clock: clock)
    await engine.sync()

    await client.setServerEntries(nil)
    await client.setEntryPagesResponse([
      FeedbinFixtures.entriesPage([try entry(3, createdAfterBase: 600)], hasNextPage: true),
      FeedbinFixtures.entriesPage([try entry(2, createdAfterBase: 300)]),
    ])
    let laterPageGate = AsyncGate()
    defer { laterPageGate.open() }
    await client.holdLaterEntryPages(until: laterPageGate)
    clock.now = serverBase.addingTimeInterval(900)
    let syncHandle = Task { await engine.sync() }
    try await waitUntil("the first page is persisted") { await (try? writer.entryCount()) == 2 }
    syncHandle.cancel()
    laterPageGate.open()
    await syncHandle.value

    #expect(engine.isSyncing == false)
    #expect(engine.lastError == nil)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == covered.createdAt)
    #expect(engine.lastSyncDate == serverBase)
  }

  @Test
  func requestCancelledAsURLErrorKeepsTheCursorAndTheEarlierError() async throws {
    let client = FakeFeedbinClient()
    let covered = try entry(1, createdAfterBase: 0)
    await client.setServerEntries([covered])
    let clock = MacClock(serverBase)
    let (engine, _) = try await makeEngine(with: client, clock: clock)
    await engine.sync()
    await client.setSubscriptionsError(FeedbinError.unauthorized)
    await engine.sync()
    let earlierError = try #require(engine.lastError)

    await client.setSubscriptionsError(nil)
    await client.setUnreadIDsError(URLError(.cancelled))
    let unreadIDsGate = AsyncGate()
    defer { unreadIDsGate.open() }
    await client.holdUnreadIDs(until: unreadIDsGate)
    clock.now = serverBase.addingTimeInterval(900)
    let syncHandle = Task { await engine.sync() }
    try await waitUntil("the unread-IDs request waits") { await client.unreadIDsCallCount == 2 }
    syncHandle.cancel()
    unreadIDsGate.open()
    await syncHandle.value

    #expect(engine.isSyncing == false)
    #expect(engine.lastError == earlierError)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == covered.createdAt)
    #expect(engine.lastSyncDate == serverBase)
  }

  @Test
  func emptyResponseKeepsTheCursorAndRecordsTheSync() async throws {
    let client = FakeFeedbinClient()
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage([])])
    let clock = MacClock(serverBase)
    let (engine, _) = try await makeEngine(with: client, clock: clock)
    await engine.sync()

    #expect(engine.entryCoverageCursor == nil)
    #expect(engine.lastSyncDate == serverBase)

    let covered = try entry(1, createdAfterBase: 0)
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage([covered])])
    await engine.sync()
    await client.setEntryPagesResponse([FeedbinFixtures.entriesPage([])])
    clock.now = serverBase.addingTimeInterval(300)
    await engine.sync()

    #expect(engine.entryCoverageCursor?.newestCreatedAt == covered.createdAt)
    #expect(engine.lastSyncDate == serverBase.addingTimeInterval(300))
    let sinceLog = await Self.sinceLog(client)
    #expect(sinceLog.first == engine.queryCutoffDate)
    #expect(sinceLog.dropFirst().first == engine.queryCutoffDate)
  }

  /// The Mac clock runs three hours behind or ahead of the Feedbin clock.
  @Test(arguments: [-3 * 3600.0, 3 * 3600.0])
  func cursorFollowsTheServerClockNotTheMacClock(_ macClockOffset: TimeInterval) async throws {
    let client = FakeFeedbinClient()
    let covered = try entry(1, createdAfterBase: 0)
    await client.setServerEntries([covered])
    let macNow = serverBase.addingTimeInterval(macClockOffset)
    let (engine, writer) = try await makeEngine(with: client, clock: MacClock(macNow))
    await engine.sync()

    #expect(engine.entryCoverageCursor?.newestCreatedAt == covered.createdAt)
    #expect(engine.lastSyncDate == macNow)

    let next = try entry(2, createdAfterBase: 60)
    await client.setServerEntries([covered, next])
    await engine.sync()
    #expect(try await writer.entryCount() == 2)
  }

  @Test
  func lastSyncDateWithoutACursorFetchesTheFullWindowOnce() async throws {
    defaults.set(serverBase, forKey: lastSyncDateUserDefaultsKey)
    let client = FakeFeedbinClient()
    let missed = try entry(1, createdAfterBase: -600)
    await client.setServerEntries([missed])
    let (engine, writer) = try await makeEngine(with: client, clock: MacClock(serverBase))
    await engine.sync()

    let sinceLog = await Self.sinceLog(client)
    #expect(sinceLog.first == engine.queryCutoffDate)
    #expect(try await writer.entryCount() == 1)
    #expect(engine.entryCoverageCursor?.newestCreatedAt == missed.createdAt)
  }
}

/// A settable Mac clock for `SyncEngine.now`.
@MainActor
private final class MacClock {
  var now: Date

  init(_ now: Date) {
    self.now = now
  }
}
