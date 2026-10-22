import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.feeder.app", category: "TimelineState")

// MARK: - Timeline state

/// Owns the refresh scheduling and the read intents of one window. A version
/// bumps only after a write that the owner started returns without an error,
/// or after an engine signal that follows a commit. The init has no side
/// effects: SwiftUI can build an owner and discard it.
@MainActor
@Observable
final class TimelineState {
  enum FlushReason {
    case sidebarChange
    case filterChange
    case sceneInactive
  }

  /// Identifies this window in the `SyncEngine` registrations.
  @ObservationIgnored
  let windowID = UUID()
  @ObservationIgnored
  private let writer: DataWriter
  @ObservationIgnored
  private let reader: DataReader
  @ObservationIgnored
  private let readQueue: SyncEngine

  /// Opened articles that are not yet read in the store. The rows render dim.
  /// Each change goes to the quit record synchronously.
  private(set) var pendingReadIDs: Set<Int> = [] {
    didSet { readQueue.recordPendingReads(pendingReadIDs, forWindow: windowID) }
  }
  /// The cached sidebar aggregation. Only `refreshUnreadSnapshot(cutoffDate:)`
  /// writes it; never aggregate inside `body`.
  private(set) var unreadSnapshot: UnreadCountsSnapshot = .empty
  /// A bump refetches the loaded article window and the unread snapshot.
  private(set) var listVersion = 0
  /// A bump refetches the unread snapshot only.
  private(set) var snapshotVersion = 0
  /// Bumps after the data of a previous account is deleted. The article list
  /// and the snapshot key include it, so a read of the old session is
  /// cancelled.
  private(set) var accountDataVersion = 0
  /// A sync page committed, and the list refresh waits for its dwell.
  private(set) var pendingSyncRefresh = false
  /// A classification result committed, and the list refresh waits for its
  /// dwell.
  private(set) var pendingClassificationRefresh = false

  /// Bumps when an account switch starts. An async read-intent effect that
  /// started under an older value is dropped.
  @ObservationIgnored
  private var sessionGeneration = 0
  @ObservationIgnored
  private var isSceneActive = true
  @ObservationIgnored
  private var owesListRefreshOnResume = false
  /// The classified count of the running batch at the last refresh request.
  @ObservationIgnored
  private var classificationBaseline = 0
  /// Unread rows of the loaded window, one side of the overlay prune.
  @ObservationIgnored
  private var renderedUnreadIDs: Set<Int> = []

  init(store: StoreActors, readQueue: SyncEngine) {
    writer = store.writer
    reader = store.reader
    self.readQueue = readQueue
  }

  // MARK: - Read intents

  /// An article was selected. An unread article joins the overlay one yield
  /// later, so the selection commit renders first. Nothing is written to the
  /// store here.
  @discardableResult
  func entrySelected(feedbinEntryID: Int, isRead: Bool) -> Task<Void, Never>? {
    guard !isRead else { return nil }
    let generation = sessionGeneration
    return applyPendingReadAfterYield(feedbinEntryID: feedbinEntryID) { id in
      guard generation == self.sessionGeneration else { return }
      self.pendingReadIDs.insert(id)
    }
  }

  /// Queue the overlay, then write it as read. The refresh follows only a
  /// committed write. On failure the IDs stay queued and stay in the overlay,
  /// and the next sync writes them as read. Returns `nil` when the overlay is
  /// empty.
  @discardableResult
  func flushPendingReads(_ reason: FlushReason) -> Task<Void, Never>? {
    if reason == .sceneInactive { isSceneActive = false }
    let ids = pendingReadIDs
    guard !ids.isEmpty else { return nil }
    readQueue.queueReadIDs(ids)
    let generation = sessionGeneration
    let writer = writer
    return Task {
      do {
        try await writer.markEntriesRead(feedbinEntryIDs: ids)
      } catch {
        logger.error("Read flush failed: \(error.localizedDescription)")
        return
      }
      guard generation == sessionGeneration else { return }
      snapshotVersion &+= 1
      switch reason {
      case .sidebarChange:
        break
      case .filterChange:
        // The flipped rows change membership in the new filter's window.
        listVersion &+= 1
      case .sceneInactive:
        // Background work pauses while the window is not visible.
        if isSceneActive { listVersion &+= 1 } else { owesListRefreshOnResume = true }
      }
    }
  }

  /// The window closed. Queue the overlay and write it as read, then release
  /// the overlay and its quit record, and drop every read-intent effect that
  /// is still in flight. A later flush of this owner then finds an empty
  /// overlay, so a pushed ID is never queued again. Returns `nil` when the
  /// overlay is empty.
  @discardableResult
  func windowClosed() -> Task<Void, Never>? {
    let ids = pendingReadIDs
    if !ids.isEmpty { readQueue.queueReadIDs(ids) }
    sessionGeneration &+= 1
    pendingReadIDs = []
    renderedUnreadIDs = []
    guard !ids.isEmpty else { return nil }
    let writer = writer
    return Task {
      do {
        try await writer.markEntriesRead(feedbinEntryIDs: ids)
      } catch {
        // The IDs stay queued: the next sync or launch writes them as read.
        logger.error("Close flush failed: \(error.localizedDescription)")
      }
    }
  }

  /// The window became active again. A refresh that a background flush owes
  /// runs now.
  func sceneBecameActive() {
    isSceneActive = true
    guard owesListRefreshOnResume else { return }
    owesListRefreshOnResume = false
    listVersion &+= 1
  }

  /// Mark the plan's rows as read. The rows dim at once; the list refreshes
  /// only after the store write commits.
  @discardableResult
  func markAllAsRead(_ plan: MarkAllReadPlan) -> Task<Void, Never> {
    pendingReadIDs.formUnion(plan.optimisticIDs)
    let generation = sessionGeneration
    return Task {
      let outcome = await readQueue.markAllAsRead(scope: plan.markTarget)
      guard generation == sessionGeneration else { return }
      switch outcome {
      case .written:
        listVersion &+= 1
      case .nothingToMark:
        // The overlay can hold rows that are already read in the store.
        snapshotVersion &+= 1
      case .failed:
        break
      }
    }
  }

  /// The loaded window changed. Its unread rows are the second side of the
  /// overlay prune.
  func visibleEntriesChanged(renderedUnreadIDs: Set<Int>) {
    self.renderedUnreadIDs = renderedUnreadIDs
    prunePendingReadIDs()
  }

  /// Release an overlay ID only when the snapshot and the rendered rows both
  /// show it read, so a snapshot that lands before the rows refetch cannot
  /// un-dim a row.
  private func prunePendingReadIDs() {
    guard !pendingReadIDs.isEmpty else { return }
    let retained = retainedPendingReadIDs(
      pending: pendingReadIDs,
      snapshotUnread: unreadSnapshot.unreadFeedbinEntryIDs,
      renderedUnread: renderedUnreadIDs
    )
    if retained != pendingReadIDs { pendingReadIDs = retained }
  }

  // MARK: - Unread snapshot

  /// The key of the snapshot task. A change refetches the snapshot.
  func unreadSnapshotKey(folderCount: Int, categoryCount: Int, cutoffDate: Date) -> String {
    let cutoffSeconds = Int(cutoffDate.timeIntervalSinceReferenceDate)
    return "\(listVersion)|\(snapshotVersion)|\(accountDataVersion)|\(folderCount)|\(categoryCount)|\(cutoffSeconds)"
  }

  /// Fetch the snapshot on the reader actor and apply it, unless the task was
  /// cancelled or an account switch started meanwhile.
  func refreshUnreadSnapshot(cutoffDate: Date) async {
    let generation = sessionGeneration
    let fresh = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoffDate)
    guard !Task.isCancelled, generation == sessionGeneration, let fresh else { return }
    unreadSnapshot = fresh
    prunePendingReadIDs()
  }

  // MARK: - Engine signals

  /// A sync page or a read-state update committed. The list refreshes after
  /// the sync dwell.
  func syncPagePersisted() {
    pendingSyncRefresh = true
  }

  /// A sync ended. Only a sync that changed rows refreshes the list.
  func syncFinished(changedCount: Int) {
    if changedCount > 0 { listVersion &+= 1 }
  }

  /// A classification progress tick. It asks for a refresh only when the
  /// classified count grew, so a batch whose writes all fail sends none. A
  /// smaller count belongs to a new batch that replaced the running batch.
  func classificationProgressed(classifiedCount: Int) {
    if classifiedCount < classificationBaseline { classificationBaseline = 0 }
    guard classifiedCount > classificationBaseline else { return }
    classificationBaseline = classifiedCount
    pendingClassificationRefresh = true
  }

  /// A cancelled batch committed results that no progress tick carried.
  func classificationResultsCommitted() {
    pendingClassificationRefresh = true
  }

  /// A classification batch ended.
  func classificationFinished(classifiedCount: Int) {
    classificationBaseline = 0
    if classifiedCount > 0 { pendingClassificationRefresh = true }
  }

  /// A category moved to another folder, so folder timelines change.
  func categoryFoldersChanged() {
    listVersion &+= 1
  }

  /// The sync dwell ended.
  func drainSyncRefresh() {
    guard pendingSyncRefresh else { return }
    pendingSyncRefresh = false
    listVersion &+= 1
  }

  /// The classification dwell ended.
  func drainClassificationRefresh() {
    guard pendingClassificationRefresh else { return }
    pendingClassificationRefresh = false
    listVersion &+= 1
  }

  // MARK: - Account switch

  /// An account switch starts: drop the overlay and every read-intent effect
  /// that is still in flight.
  func resetForAccountSwitch() {
    sessionGeneration &+= 1
    pendingReadIDs = []
    renderedUnreadIDs = []
  }

  /// The previous account's data is deleted. The list and the snapshot reload.
  func accountDataDeleted() {
    accountDataVersion &+= 1
  }
}
