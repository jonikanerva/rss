import SwiftUI

// MARK: - Engine signal router

/// Forwards the commit signals of the sync and classification engines to the
/// window's `TimelineState`.
///
/// It must stay a leaf `View`, not a `ViewModifier`: reading the per-page
/// counters in `ContentView.body` would invalidate the whole split view on
/// each sync page and each classification tick. Reading them here re-evaluates
/// only this zero-size view.
struct TimelineSignalRouter: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  let timeline: TimelineState

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: syncEngine.lastPersistedPageVersion) {
        timeline.syncPagePersisted()
      }
      .onChange(of: syncEngine.isSyncing) { _, isSyncing in
        if !isSyncing { timeline.syncFinished(changedCount: syncEngine.lastSyncChangedEntryCount) }
      }
      .onChange(of: classificationEngine.batchProgressVersion) {
        timeline.classificationProgressed(classifiedCount: classificationEngine.classifiedCount)
      }
      .onChange(of: classificationEngine.unreportedCommitVersion) {
        timeline.classificationResultsCommitted()
      }
      .onChange(of: classificationEngine.isClassifying) { _, isClassifying in
        if !isClassifying {
          timeline.classificationFinished(classifiedCount: classificationEngine.lastBatchClassifiedCount)
        }
      }
  }
}

/// Mounts `TimelineSignalRouter` as an invisible background sibling.
struct TimelineSignalRouterModifier: ViewModifier {
  let timeline: TimelineState

  func body(content: Content) -> some View {
    content.background(TimelineSignalRouter(timeline: timeline))
  }
}

// MARK: - Refresh tasks

/// The timed work of the window's `TimelineState`. SwiftUI owns these tasks,
/// so a key change and a closed window cancel them.
struct TimelineRefreshTasks: ViewModifier {
  /// Hold time before a classification refresh while a row is selected. A
  /// batch can add or remove rows between the visible rows, so the refresh
  /// waits until the selection has been stable for this long.
  static let classificationDwell: Duration = .seconds(4)
  /// Coalescing window for classification refreshes with no selected row.
  static let classificationIdleDwell: Duration = .seconds(1)
  /// Coalescing window for sync-page refreshes: it collapses a burst of pages
  /// into one refetch.
  static let syncDwell: Duration = .milliseconds(750)

  let timeline: TimelineState
  let cutoffDate: Date
  let folderCount: Int
  let categoryCount: Int
  let selectedFeedbinEntryID: Int?

  func body(content: Content) -> some View {
    content
      .task(
        id: timeline.unreadSnapshotKey(
          folderCount: folderCount, categoryCount: categoryCount, cutoffDate: cutoffDate)
      ) {
        await timeline.refreshUnreadSnapshot(cutoffDate: cutoffDate)
      }
      // A selection change restarts the dwell. A new progress tick does not,
      // because the pending flag is already set.
      .task(id: "\(selectedFeedbinEntryID ?? -1)|\(timeline.pendingClassificationRefresh)") {
        guard timeline.pendingClassificationRefresh else { return }
        let dwell = selectedFeedbinEntryID == nil ? Self.classificationIdleDwell : Self.classificationDwell
        try? await Task.sleep(for: dwell)
        guard !Task.isCancelled else { return }
        timeline.drainClassificationRefresh()
      }
      .task(id: "sync|\(selectedFeedbinEntryID ?? -1)|\(timeline.pendingSyncRefresh)") {
        guard timeline.pendingSyncRefresh else { return }
        try? await Task.sleep(for: Self.syncDwell)
        guard !Task.isCancelled else { return }
        timeline.drainSyncRefresh()
      }
  }
}
