import Foundation
import Testing

@testable import Feeder

/// `TimelineState` owns the refresh scheduling and the read intents of one
/// window. The tests use the real writer, reader, and `SyncEngine` on an
/// in-memory or failing store, with isolated defaults. They call the owner
/// directly, so no test sleeps.
@MainActor
@Suite("TimelineState")
struct TimelineStateTests {
  private let isolatedDefaults: IsolatedDefaults
  private var defaults: UserDefaults { isolatedDefaults.defaults }

  init() throws {
    isolatedDefaults = try IsolatedDefaults("TimelineState")
  }

  // MARK: - Builders

  private func makeEngine(writer: DataWriter) -> SyncEngine {
    let engine = SyncEngine(defaults: defaults, credentialStore: MemoryFeedbinCredentialStore(), account: .unused)
    engine.attachWriter(writer)
    return engine
  }

  private func makeTimeline(store: StoreActors, engine: SyncEngine) -> TimelineState {
    TimelineState(store: store, readQueue: engine)
  }

  /// Unread entries in one feed, published now, so the engine's cutoff keeps
  /// them.
  private func seedUnread(_ ids: [Int], in writer: DataWriter) async throws {
    try await writer.syncFeeds([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    let published = formatDateForFeedbin(.now)
    let entries = try ids.map { try FeedbinFixtures.entry(id: $0, feedId: 100, published: published) }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
  }

  private func inMemory() async throws -> (StoreActors, SyncEngine) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    return (StoreActors(writer: writer, reader: reader), makeEngine(writer: writer))
  }

  private var queuedReadIDs: Set<Int> {
    Set(defaults.array(forKey: pendingReadIDsUserDefaultsKey) as? [Int] ?? [])
  }

  private func isRead(_ id: Int, _ store: StoreActors) async throws -> Bool? {
    try await store.writer.fetchEntrySnapshot(feedbinEntryID: id)?.isRead
  }

  /// Put `id` in the overlay through the selection path.
  private func select(_ id: Int, _ timeline: TimelineState) async {
    await timeline.entrySelected(feedbinEntryID: id, isRead: false)?.value
  }

  // MARK: - Commit notification

  @Test
  func sidebarFlushRefreshesTheSnapshotOnlyAfterTheCommit() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    let flush = try #require(timeline.flushPendingReads(.sidebarChange))
    #expect(queuedReadIDs == [1])
    #expect(timeline.snapshotVersion == 0)
    await flush.value

    #expect(try await isRead(1, store) == true)
    #expect(timeline.snapshotVersion == 1)
    #expect(timeline.listVersion == 0)
  }

  @Test
  func filterFlushRefreshesTheListAfterTheCommit() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    await timeline.flushPendingReads(.filterChange)?.value

    #expect(timeline.listVersion == 1)
    #expect(timeline.snapshotVersion == 1)
  }

  @Test
  func emptyOverlayFlushesNothing() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    #expect(timeline.flushPendingReads(.filterChange) == nil)
    #expect(queuedReadIDs.isEmpty)
  }

  @Test
  func writtenMarkAllRefreshesTheListOnce() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1, 2], clearsArticleSelection: true)

    let task = timeline.markAllAsRead(plan)
    #expect(timeline.pendingReadIDs == [1, 2])
    await task.value

    #expect(timeline.listVersion == 1)
    #expect(queuedReadIDs == [1, 2])
    #expect(try await isRead(2, store) == true)
  }

  @Test
  func markAllWithNothingUnreadRefreshesTheSnapshotOnly() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [], clearsArticleSelection: false)

    await timeline.markAllAsRead(plan).value

    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 1)
  }

  // MARK: - No success signal on failure

  @Test
  func failedFlushSendsNoSignalAndKeepsTheOverlayAndTheQueue() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1], in: writer)
    let store = StoreActors(writer: writer, reader: reader)
    let timeline = makeTimeline(store: store, engine: makeEngine(writer: writer))
    await select(1, timeline)
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")

    await timeline.flushPendingReads(.filterChange)?.value

    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 0)
    #expect(timeline.pendingReadIDs == [1])
    #expect(queuedReadIDs == [1])
    #expect(try await isRead(1, store) == false)
  }

  @Test
  func failedMarkAllSendsNoSignal() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1, 2], in: writer)
    let timeline = makeTimeline(
      store: StoreActors(writer: writer, reader: reader), engine: makeEngine(writer: writer))
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1, 2], clearsArticleSelection: true)

    await timeline.markAllAsRead(plan).value

    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 0)
  }

  /// A classification batch whose writes all fail reports progress with a
  /// classified count of 0. It asks for no refresh.
  @Test
  func classificationTicksWithoutNewResultsSendNoRefresh() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    timeline.classificationProgressed(classifiedCount: 0)
    timeline.classificationProgressed(classifiedCount: 0)
    timeline.classificationFinished(classifiedCount: 0)

    #expect(timeline.pendingClassificationRefresh == false)
  }

  @Test
  func quietSyncLeavesTheListUntouched() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    timeline.syncFinished(changedCount: 0)

    #expect(timeline.listVersion == 0)
  }

  // MARK: - Single-article read state

  private var queuedUnreadIDs: Set<Int> {
    Set(defaults.array(forKey: pendingUnreadIDsUserDefaultsKey) as? [Int] ?? [])
  }

  @Test
  func markUnreadQueuesBeforeTheWriteAndRefreshesAfterTheCommit() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    await timeline.flushPendingReads(.sceneInactive)?.value
    timeline.sceneBecameActive()
    let listVersion = timeline.listVersion

    let task = timeline.markUnread(feedbinEntryID: 1)
    #expect(timeline.pendingReadIDs.isEmpty)
    #expect(timeline.pendingUnreadIDs == [1])
    #expect(timeline.isRead(feedbinEntryID: 1, storeIsRead: true) == false)
    #expect(queuedReadIDs.isEmpty)
    #expect(queuedUnreadIDs == [1])
    #expect(timeline.listVersion == listVersion)
    await task.value

    #expect(try await isRead(1, store) == false)
    #expect(timeline.listVersion == listVersion + 1)
  }

  @Test
  func unreadOverlayStaysUntilTheSnapshotAndTheRowsShowTheArticleUnread() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    try await store.writer.markEntriesRead(feedbinEntryIDs: [1])
    let timeline = makeTimeline(store: store, engine: engine)
    await timeline.markUnread(feedbinEntryID: 1).value

    timeline.visibleEntriesChanged(renderedUnreadIDs: [])
    await timeline.refreshUnreadSnapshot(cutoffDate: .distantPast)
    #expect(timeline.pendingUnreadIDs == [1])

    timeline.visibleEntriesChanged(renderedUnreadIDs: [1])
    #expect(timeline.pendingUnreadIDs.isEmpty)
  }

  @Test
  func markReadAfterMarkUnreadJoinsTheReadOverlay() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await timeline.markUnread(feedbinEntryID: 1).value

    timeline.markRead(feedbinEntryID: 1)
    #expect(timeline.pendingUnreadIDs.isEmpty)
    #expect(timeline.isRead(feedbinEntryID: 1, storeIsRead: false) == true)
    await timeline.flushPendingReads(.sidebarChange)?.value

    #expect(queuedReadIDs == [1])
    #expect(queuedUnreadIDs.isEmpty)
    #expect(try await isRead(1, store) == true)
  }

  @Test
  func failedMarkUnreadSendsNoSignalAndKeepsTheQueue() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1], in: writer)
    try await writer.markEntriesRead(feedbinEntryIDs: [1])
    let store = StoreActors(writer: writer, reader: reader)
    let timeline = makeTimeline(store: store, engine: makeEngine(writer: writer))
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")

    await timeline.markUnread(feedbinEntryID: 1).value

    #expect(timeline.listVersion == 0)
    #expect(timeline.pendingUnreadIDs == [1])
    #expect(queuedUnreadIDs == [1])
    #expect(try await isRead(1, store) == true)
  }

  // MARK: - Scheduling

  @Test
  func syncPageBurstCoalescesToOneRefresh() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    for _ in 0..<5 { timeline.syncPagePersisted() }
    timeline.drainSyncRefresh()
    timeline.drainSyncRefresh()

    #expect(timeline.listVersion == 1)
    #expect(timeline.pendingSyncRefresh == false)
  }

  @Test
  func classificationResultsRequestOneRefreshPerGrowth() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    timeline.classificationProgressed(classifiedCount: 2)
    timeline.drainClassificationRefresh()
    timeline.classificationProgressed(classifiedCount: 2)
    #expect(timeline.pendingClassificationRefresh == false)
    timeline.classificationProgressed(classifiedCount: 3)
    #expect(timeline.pendingClassificationRefresh == true)
    timeline.drainClassificationRefresh()

    #expect(timeline.listVersion == 2)
  }

  @Test
  func unreportedCommittedResultsRequestARefresh() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    timeline.classificationResultsCommitted()
    timeline.drainClassificationRefresh()

    #expect(timeline.listVersion == 1)
  }

  /// The next batch counts from 0 again.
  @Test
  func finishedBatchResetsTheClassificationBaseline() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)
    timeline.classificationProgressed(classifiedCount: 5)
    timeline.classificationFinished(classifiedCount: 5)
    timeline.drainClassificationRefresh()

    timeline.classificationProgressed(classifiedCount: 1)

    #expect(timeline.pendingClassificationRefresh == true)
  }

  /// A new batch can replace a running batch with no finish signal between
  /// them. Its smaller count starts a new baseline.
  @Test
  func replacingBatchRequestsARefreshForItsFirstResult() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)
    timeline.classificationProgressed(classifiedCount: 5)
    timeline.drainClassificationRefresh()

    timeline.classificationProgressed(classifiedCount: 0)
    #expect(timeline.pendingClassificationRefresh == false)
    timeline.classificationProgressed(classifiedCount: 1)

    #expect(timeline.pendingClassificationRefresh == true)
  }

  @Test
  func backgroundFlushOwesOneRefreshThatResumeConsumes() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    await timeline.flushPendingReads(.sceneInactive)?.value
    #expect(timeline.listVersion == 0)
    timeline.sceneBecameActive()
    timeline.sceneBecameActive()

    #expect(timeline.listVersion == 1)
  }

  /// The window became active before the background write committed, so the
  /// commit refreshes at once and owes nothing.
  @Test
  func backgroundFlushThatCommitsAfterResumeRefreshesAtOnce() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    let flush = timeline.flushPendingReads(.sceneInactive)
    timeline.sceneBecameActive()
    await flush?.value
    timeline.sceneBecameActive()

    #expect(timeline.listVersion == 1)
  }

  // MARK: - List and sidebar consistency

  /// A list refresh also refetches the sidebar counts, so the list and the
  /// sidebar never show different read states for long. A snapshot-only
  /// refresh changes the key too.
  @Test
  func everyRefreshChangesTheSnapshotKey() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)
    let key = { timeline.unreadSnapshotKey(folderCount: 1, categoryCount: 2, cutoffDate: .distantPast) }
    var keys = [key()]

    timeline.categoryFoldersChanged()
    keys.append(key())
    timeline.syncFinished(changedCount: 1)
    keys.append(key())
    timeline.accountDataDeleted()
    keys.append(key())
    let nothingToMark = MarkAllReadPlan(markTarget: .all, optimisticIDs: [], clearsArticleSelection: false)
    await timeline.markAllAsRead(nothingToMark).value
    #expect(timeline.snapshotVersion == 1)
    keys.append(key())

    #expect(Set(keys).count == keys.count)
  }

  /// The overlay releases an ID only when both the snapshot and the rendered
  /// rows show it read, in either order.
  @Test(arguments: [true, false])
  func overlayReleasesAnIDOnlyWhenSnapshotAndRowsAgree(snapshotFirst: Bool) async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await timeline.refreshUnreadSnapshot(cutoffDate: .distantPast)
    timeline.visibleEntriesChanged(renderedUnreadIDs: [1, 2])
    await select(1, timeline)
    await timeline.flushPendingReads(.sidebarChange)?.value

    if snapshotFirst {
      await timeline.refreshUnreadSnapshot(cutoffDate: .distantPast)
      #expect(timeline.pendingReadIDs == [1])
      timeline.visibleEntriesChanged(renderedUnreadIDs: [2])
    } else {
      timeline.visibleEntriesChanged(renderedUnreadIDs: [2])
      #expect(timeline.pendingReadIDs == [1])
      await timeline.refreshUnreadSnapshot(cutoffDate: .distantPast)
    }

    #expect(timeline.pendingReadIDs.isEmpty)
    #expect(timeline.unreadSnapshot.unreadFeedbinEntryIDs == [2])
  }

  // MARK: - Stale results

  @Test
  func accountSwitchDropsALateSelectionInsertion() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    let insertion = timeline.entrySelected(feedbinEntryID: 1, isRead: false)
    timeline.resetForAccountSwitch()
    await insertion?.value

    #expect(timeline.pendingReadIDs.isEmpty)
  }

  @Test
  func accountSwitchDropsTheSignalOfAnEarlierFlush() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    let flush = timeline.flushPendingReads(.filterChange)
    timeline.resetForAccountSwitch()
    await flush?.value

    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 0)
    #expect(timeline.pendingReadIDs.isEmpty)
  }

  @Test
  func accountSwitchDropsTheSignalOfAnEarlierMarkAll() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1], clearsArticleSelection: true)

    let task = timeline.markAllAsRead(plan)
    timeline.resetForAccountSwitch()
    await task.value

    #expect(timeline.listVersion == 0)
    #expect(timeline.pendingReadIDs.isEmpty)
  }

  @Test
  func deletedAccountDataReloadsTheList() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    timeline.resetForAccountSwitch()
    #expect(timeline.accountDataVersion == 0)
    timeline.accountDataDeleted()

    #expect(timeline.accountDataVersion == 1)
  }

  // MARK: - Integration contracts

  /// A selection does not write the store: the overlay holds the read until a
  /// flush.
  @Test
  func selectionWritesNothingToTheStore() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)

    await select(1, timeline)

    #expect(timeline.pendingReadIDs == [1])
    #expect(try await isRead(1, store) == false)
    #expect(queuedReadIDs.isEmpty)
  }

  /// One main window per owner: a new window starts empty, and the quit step
  /// queues the reads of every window.
  @Test
  func eachWindowRecordsItsOwnReadsForTheQuitStep() async throws {
    let (store, engine) = try await inMemory()
    let first = makeTimeline(store: store, engine: engine)
    await select(1, first)
    let second = makeTimeline(store: store, engine: engine)
    #expect(second.pendingReadIDs.isEmpty)
    await select(2, second)

    engine.queueRecordedPendingReads()

    #expect(queuedReadIDs == [1, 2])
  }

  /// A window that goes away without a close flush keeps its quit record.
  @Test
  func closedWindowReadsStillReachTheQuitQueue() async throws {
    let (store, engine) = try await inMemory()
    var window: TimelineState? = makeTimeline(store: store, engine: engine)
    if let window { await select(7, window) }
    window = nil

    engine.queueRecordedPendingReads()

    #expect(window == nil)
    #expect(queuedReadIDs == [7])
  }

  // MARK: - Window close

  /// A closed window queues its overlay, writes it as read, and releases its
  /// quit record. The closed window sends no refresh signal.
  @Test
  func windowCloseQueuesWritesAndReleasesTheOverlay() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    let flush = try #require(timeline.windowClosed())
    #expect(queuedReadIDs == [1])
    #expect(timeline.pendingReadIDs.isEmpty)
    await flush.value

    #expect(try await isRead(1, store) == true)
    #expect(try await isRead(2, store) == false)
    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 0)
  }

  /// The Cmd-W journey: read an article, close the window, reopen it. The new
  /// window shows the article as read, and the read is in the Feedbin queue.
  @Test
  func readCloseReopenKeepsTheArticleRead() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let closed = makeTimeline(store: store, engine: engine)
    await select(1, closed)

    await closed.windowClosed()?.value
    let reopened = makeTimeline(store: store, engine: engine)
    await reopened.refreshUnreadSnapshot(cutoffDate: .distantPast)

    #expect(reopened.pendingReadIDs.isEmpty)
    #expect(reopened.unreadSnapshot.unreadFeedbinEntryIDs == [2])
    #expect(queuedReadIDs == [1])
  }

  /// A push can drain the queue after the close. A later scene flush and the
  /// quit step must not queue the pushed IDs again.
  @Test
  func flushAndQuitAfterTheCloseQueueNothingAgain() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    await timeline.windowClosed()?.value
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)

    #expect(timeline.flushPendingReads(.sceneInactive) == nil)
    engine.queueRecordedPendingReads()

    #expect(queuedReadIDs.isEmpty)
  }

  /// The scene flush can run before the close, and a push can drain the
  /// queue between them. The close then queues nothing and sends no late
  /// signal.
  @Test
  func sceneFlushBeforeTheCloseIsHarmless() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)

    let sceneFlush = timeline.flushPendingReads(.sceneInactive)
    #expect(queuedReadIDs == [1])
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)
    let closeFlush = timeline.windowClosed()
    await sceneFlush?.value
    await closeFlush?.value
    engine.queueRecordedPendingReads()

    #expect(queuedReadIDs.isEmpty)
    #expect(try await isRead(1, store) == true)
    #expect(timeline.pendingReadIDs.isEmpty)
    #expect(timeline.listVersion == 0)
    #expect(timeline.snapshotVersion == 0)
  }

  /// A selection that lands after the close must not add a quit record for
  /// the closed window.
  @Test
  func windowCloseDropsALateSelectionInsertion() async throws {
    let (store, engine) = try await inMemory()
    let timeline = makeTimeline(store: store, engine: engine)

    let insertion = timeline.entrySelected(feedbinEntryID: 1, isRead: false)
    #expect(timeline.windowClosed() == nil)
    await insertion?.value
    engine.queueRecordedPendingReads()

    #expect(timeline.pendingReadIDs.isEmpty)
    #expect(queuedReadIDs.isEmpty)
  }

  /// A failed close write keeps the IDs queued, so the next sync or launch
  /// writes them as read.
  @Test
  func failedCloseWriteKeepsTheQueue() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1], in: writer)
    let store = StoreActors(writer: writer, reader: reader)
    let timeline = makeTimeline(store: store, engine: makeEngine(writer: writer))
    await select(1, timeline)
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")

    await timeline.windowClosed()?.value

    #expect(queuedReadIDs == [1])
    #expect(try await isRead(1, store) == false)
  }

  /// A queued ID that the store holds as unread again and that the user opens
  /// again is a new read: the close queues it.
  @Test
  func windowCloseQueuesANewReadOfAQueuedID() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    timeline.flushPendingReads(.sidebarChange)
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)
    await select(1, timeline)

    timeline.windowClosed()

    #expect(queuedReadIDs == [1])
  }

  /// Mark All queues its rows. A push can drain the queue before the close,
  /// and the close does not queue the rows again.
  @Test
  func windowCloseSkipsTheRowsOfMarkAll() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1, 2], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1, 2], clearsArticleSelection: true)
    await timeline.markAllAsRead(plan).value
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)

    timeline.windowClosed()

    #expect(queuedReadIDs.isEmpty)
  }

  /// A Mark All whose write fails after the queue step leaves its rows
  /// queued. A push can drain the queue, and a later flush or the close must
  /// not queue the rows again. The flush still writes them as read.
  @Test
  func failedMarkAllWriteRowsAreNotQueuedAgain() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1], in: writer)
    let store = StoreActors(writer: writer, reader: reader)
    let timeline = makeTimeline(store: store, engine: makeEngine(writer: writer))
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1], clearsArticleSelection: true)
    await timeline.markAllAsRead(plan).value
    #expect(queuedReadIDs == [1])
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)
    try failing.dropFailingTrigger()

    await timeline.flushPendingReads(.sidebarChange)?.value
    timeline.windowClosed()

    #expect(queuedReadIDs.isEmpty)
    #expect(try await isRead(1, store) == true)
  }

  /// A Mark All that fails before its queue step leaves the rows unqueued, so
  /// the close queues them.
  @Test
  func windowCloseQueuesTheRowsOfAMarkAllThatQueuedNothing() async throws {
    let (store, _) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    // No writer: Mark All fails before it queues a row.
    let engine = SyncEngine(defaults: defaults, credentialStore: MemoryFeedbinCredentialStore(), account: .unused)
    let timeline = makeTimeline(store: store, engine: engine)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1], clearsArticleSelection: true)
    await timeline.markAllAsRead(plan).value

    timeline.windowClosed()

    #expect(queuedReadIDs == [1])
  }

  /// A close while Mark All runs queues the overlay: Mark All can fail before
  /// it queues anything.
  @Test
  func windowCloseDuringMarkAllQueuesTheOverlay() async throws {
    let (store, _) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    // No writer: Mark All fails before it queues a row.
    let engine = SyncEngine(defaults: defaults, credentialStore: MemoryFeedbinCredentialStore(), account: .unused)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    let plan = MarkAllReadPlan(markTarget: .all, optimisticIDs: [1], clearsArticleSelection: true)

    let markAll = timeline.markAllAsRead(plan)
    let close = timeline.windowClosed()
    await markAll.value
    await close?.value
    engine.queueRecordedPendingReads()

    #expect(queuedReadIDs == [1])
  }

  // MARK: - Repeated flushes

  /// A scene flush keeps the overlay until a refresh prunes it. A push can
  /// drain the queue before the next flush, and that flush must not queue
  /// the pushed IDs again.
  @Test
  func secondFlushDoesNotQueueAPushedIDAgain() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    await timeline.flushPendingReads(.sceneInactive)?.value
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)
    #expect(timeline.pendingReadIDs == [1])

    await timeline.flushPendingReads(.sidebarChange)?.value

    #expect(queuedReadIDs.isEmpty)
    #expect(try await isRead(1, store) == true)
  }

  /// A queued ID that the store holds as unread again and that the user opens
  /// again is a new read: the next flush queues it.
  @Test
  func flushQueuesANewReadOfAQueuedID() async throws {
    let (store, engine) = try await inMemory()
    try await seedUnread([1], in: store.writer)
    let timeline = makeTimeline(store: store, engine: engine)
    await select(1, timeline)
    await timeline.flushPendingReads(.sceneInactive)?.value
    defaults.removeObject(forKey: pendingReadIDsUserDefaultsKey)
    await select(1, timeline)

    await timeline.flushPendingReads(.sidebarChange)?.value

    #expect(queuedReadIDs == [1])
  }

  /// A failed flush write keeps the IDs queued and in the overlay. The next
  /// flush writes them again but does not queue them twice.
  @Test
  func flushAfterAFailedWriteRetriesTheStoreWrite() async throws {
    let failing = try FailingWriteStore()
    defer { failing.removeFolder() }
    let (writer, reader) = try await failing.makeWriterAndReader()
    try await seedUnread([1], in: writer)
    let store = StoreActors(writer: writer, reader: reader)
    let timeline = makeTimeline(store: store, engine: makeEngine(writer: writer))
    await select(1, timeline)
    try failing.installFailingTrigger("UPDATE", on: "ZENTRY")
    await timeline.flushPendingReads(.sceneInactive)?.value
    try failing.dropFailingTrigger()

    await timeline.flushPendingReads(.sidebarChange)?.value

    #expect(queuedReadIDs == [1])
    #expect(try await isRead(1, store) == true)
  }
}
