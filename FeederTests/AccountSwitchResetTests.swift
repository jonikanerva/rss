import Foundation
import Testing

@testable import Feeder

/// A switch to another Feedbin username resets the previous account. A
/// password change for the same username resets nothing.
@MainActor
@Suite("Account switch reset")
struct AccountSwitchResetTests {
  nonisolated private static let previous = FeedbinCredentials(username: "previous@example.com", password: "old-secret")
  nonisolated private static let next = FeedbinCredentials(username: "next@example.com", password: "new-secret")

  private let isolatedDefaults: IsolatedDefaults
  private var defaults: UserDefaults { isolatedDefaults.defaults }

  init() throws {
    isolatedDefaults = try IsolatedDefaults("AccountSwitchReset")
  }

  private struct DeleteFailure: Error {}

  private struct Fixture {
    let engine: SyncEngine
    let writer: DataWriter
    let previousClient: FakeFeedbinClient
    let nextClient: FakeFeedbinClient
    let events: EventLog
  }

  @MainActor
  private final class EventLog {
    var events: [String] = []
  }

  /// The engine is signed in to `previous` and holds its feed, two entries,
  /// a coverage cursor, and a `lastSyncDate`.
  private func makeFixture(
    account: FeedbinAccountPhase = .signedIn(username: previous.username), deleteFails: Bool = false
  ) async throws -> Fixture {
    let previousClient = FakeFeedbinClient()
    let nextClient = FakeFeedbinClient()
    let factory = RecordingClientFactory { $0.username == Self.previous.username ? previousClient : nextClient }
    let store = MemoryFeedbinCredentialStore(credentials: Self.previous)
    let events = EventLog()
    let engine = SyncEngine(
      defaults: defaults, credentialStore: store, account: account, makeClient: factory.make,
      deletePreviousAccountData: { writer in
        await MainActor.run { events.events.append("delete") }
        if deleteFails { throw DeleteFailure() }
        _ = try await writer.deleteAccountData()
      })
    let writer = try await DataWriterTestSupport.makeWriter()
    _ = try await writer.bootstrap()
    try await writer.syncFeeds([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    let created = formatDateForFeedbin(Date().addingTimeInterval(-3600))
    let entries = try [1, 2].map { try FeedbinFixtures.entry(id: $0, feedId: 100, published: created, createdAt: created) }
    _ = try await writer.persistEntries(entries, unreadIDs: [1, 2])
    defaults.set(Date(), forKey: lastSyncDateUserDefaultsKey)
    defaults.set(Date(), forKey: entryCoverageCursorUserDefaultsKey)
    engine.attachWriter(writer)
    engine.attachClient(previousClient)
    engine.registerAccountSwitchReset(forWindow: UUID()) { events.events.append("window") }
    engine.attachAccountSwitchWork(
      pause: { events.events.append("pause") },
      resume: { _ in events.events.append("resume") })
    return Fixture(
      engine: engine, writer: writer, previousClient: previousClient, nextClient: nextClient, events: events)
  }

  @Test
  func switchStopsTheSyncAndClearsThePreviousAccount() async throws {
    let fixture = try await makeFixture()
    let engine = fixture.engine
    let taxonomyBefore = try await fixture.writer.taxonomyCount()
    let created = formatDateForFeedbin(Date().addingTimeInterval(-60))
    await fixture.previousClient.setEntryPagesResponse([
      FeedbinFixtures.entriesPage(
        [try FeedbinFixtures.entry(id: 3, feedId: 100, published: created, createdAt: created)], hasNextPage: true),
      FeedbinFixtures.entriesPage([try FeedbinFixtures.entry(id: 4, feedId: 100, published: created, createdAt: created)]),
    ])
    let laterPageGate = AsyncGate()
    defer { laterPageGate.open() }
    await fixture.previousClient.holdLaterEntryPages(until: laterPageGate)
    let syncHandle = Task { await engine.sync() }
    try await waitUntil("the first page is persisted") { await (try? fixture.writer.entryCount()) == 3 }
    engine.queueReadIDs([1])
    engine.recordPendingReads([2], forWindow: UUID())

    let saved = try await engine.saveAccount(username: Self.next.username, password: Self.next.password)
    laterPageGate.open()
    await syncHandle.value

    #expect(saved)
    #expect(engine.account == .signedIn(username: Self.next.username))
    #expect(fixture.events.events == ["pause", "window", "delete", "resume"])
    #expect(try await fixture.writer.entryCount() == 0)
    #expect(try await fixture.writer.feedCount() == 0)
    let taxonomyAfter = try await fixture.writer.taxonomyCount()
    #expect(taxonomyAfter.folders == taxonomyBefore.folders)
    #expect(taxonomyAfter.categories == taxonomyBefore.categories)
    #expect(engine.lastSyncDate == nil)
    #expect(engine.entryCoverageCursor == nil)
    #expect(engine.isSyncing == false)
    #expect(engine.lastError == nil)

    engine.queueRecordedPendingReads()
    engine.queueReadIDs([2])
    await engine.sync()
    #expect(await fixture.nextClient.deleteUnreadEntriesCallLog.isEmpty)
    #expect(await fixture.previousClient.deleteUnreadEntriesCallLog.allSatisfy { !$0.contains(1) })
    #expect(await fixture.nextClient.fetchEntryPagesSinceLog.first == engine.queryCutoffDate)
  }

  @Test
  func failedDeleteKeepsThePreviousAccountAndItsData() async throws {
    let fixture = try await makeFixture(deleteFails: true)
    let engine = fixture.engine
    let cursor = engine.entryCoverageCursor
    let lastSyncDate = engine.lastSyncDate
    engine.queueReadIDs([1])

    await #expect(throws: DeleteFailure.self) {
      try await engine.saveAccount(username: Self.next.username, password: Self.next.password)
    }

    #expect(fixture.events.events == ["pause", "window", "delete", "resume"])
    #expect(engine.account == .signedIn(username: Self.previous.username))
    #expect(try await engine.credentialStore.load() == Self.previous)
    #expect(try await fixture.writer.entryCount() == 2)
    #expect(engine.entryCoverageCursor == cursor)
    #expect(engine.lastSyncDate == lastSyncDate)
    await engine.pushPendingReads()
    #expect(await fixture.previousClient.deleteUnreadEntriesCallLog == [[1]])
    #expect(await fixture.nextClient.deleteUnreadEntriesCallLog.isEmpty)
  }

  @Test
  func windowReadLeavesTheFilterWhenNoWindowRecordsIt() async throws {
    let fixture = try await makeFixture()
    let engine = fixture.engine
    let window = UUID()
    engine.recordPendingReads([2], forWindow: window)
    _ = try await engine.saveAccount(username: Self.next.username, password: Self.next.password)

    engine.recordPendingReads([], forWindow: window)
    engine.queueReadIDs([2])
    await engine.pushPendingReads()

    #expect(await fixture.nextClient.deleteUnreadEntriesCallLog == [[2]])
  }

  @Test
  func passwordChangeForTheSameUsernameKeepsTheData() async throws {
    let fixture = try await makeFixture()
    let engine = fixture.engine
    let cursor = engine.entryCoverageCursor
    let lastSyncDate = engine.lastSyncDate
    engine.queueReadIDs([1])

    let saved = try await engine.saveAccount(username: Self.previous.username, password: "changed-secret")

    #expect(saved)
    #expect(fixture.events.events.isEmpty)
    #expect(try await fixture.writer.entryCount() == 2)
    #expect(try await fixture.writer.feedCount() == 1)
    #expect(engine.entryCoverageCursor == cursor)
    #expect(engine.lastSyncDate == lastSyncDate)
    await engine.pushPendingReads()
    #expect(await fixture.previousClient.deleteUnreadEntriesCallLog == [[1]])
  }

  @Test
  func firstSignInResetsNothing() async throws {
    let fixture = try await makeFixture(account: .noAccount)
    let saved = try await fixture.engine.saveAccount(username: Self.next.username, password: Self.next.password)

    #expect(saved)
    #expect(fixture.events.events.isEmpty)
    #expect(try await fixture.writer.entryCount() == 2)
  }

  @Test
  func rejectedCredentialsResetNothing() async throws {
    let fixture = try await makeFixture()
    await fixture.nextClient.setVerifyResult(.success(false))

    let saved = try await fixture.engine.saveAccount(username: Self.next.username, password: Self.next.password)

    #expect(!saved)
    #expect(fixture.events.events.isEmpty)
    #expect(try await fixture.writer.entryCount() == 2)
    #expect(fixture.engine.account == .signedIn(username: Self.previous.username))
  }
}

// MARK: - Store delete

@Suite("Account data delete")
struct AccountDataDeleteTests {
  @Test
  func deleteRemovesFeedsAndEveryEntryAndKeepsTheTaxonomy() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    _ = try await writer.bootstrap()
    let taxonomyBefore = try await writer.taxonomyCount()
    try await writer.syncFeeds([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    let entries = [try FeedbinFixtures.entry(id: 1, feedId: 100), try FeedbinFixtures.entry(id: 2, feedId: 999)]
    _ = try await writer.persistEntries(entries, unreadIDs: [])

    let deletion = try await writer.deleteAccountData()

    #expect(deletion == AccountDataDeletion(feedCount: 1, entryCount: 2))
    #expect(try await writer.entryCount() == 0)
    #expect(try await writer.feedCount() == 0)
    let taxonomyAfter = try await writer.taxonomyCount()
    #expect(taxonomyAfter.folders == taxonomyBefore.folders)
    #expect(taxonomyAfter.categories == taxonomyBefore.categories)
  }
}

// MARK: - Classification pause

@MainActor
@Suite("Classification account switch pause")
struct ClassificationAccountSwitchPauseTests {
  @Test
  func pauseStopsTheWorkAndBlocksEveryStartUntilResume() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    try await writer.addCategory(label: "tech", displayName: "Tech", description: "Technology", sortOrder: 0)
    try await writer.addCategory(label: uncategorizedLabel, displayName: "Uncategorized", description: "Fallback", sortOrder: 1)
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    let published = ISO8601DateFormatter().string(from: Date())
    let entries = try (1001...1010).map {
      try FeedbinFixtures.entry(id: $0, title: "An article", content: "<p>Some article text</p>", published: published)
    }
    _ = try await writer.persistEntries(entries, unreadIDs: [])
    let provider = FakeClassificationProvider()
    await provider.configureDelay(.milliseconds(20))
    let engine = ClassificationEngine(providerFactoryOverride: { provider })
    engine.startContinuousClassification(writer: writer)
    try await waitUntil("the first request starts") { await provider.callCount >= 1 }

    await engine.pauseForAccountSwitch()
    let callsAtPause = await provider.callCount
    engine.startContinuousClassification(writer: writer)
    await engine.classifyUnclassified(writer: writer)
    try await Task.sleep(for: .milliseconds(60))

    #expect(await provider.callCount == callsAtPause)
    #expect(engine.isContinuousLoopActive == false)
    #expect(engine.currentClassificationTaskID == nil)

    engine.resumeAfterAccountSwitch(writer: writer)
    #expect(engine.isContinuousLoopActive)
    try await waitUntil("a request starts after resume") { await provider.callCount > callsAtPause }
    engine.stopContinuousClassification()
  }
}
