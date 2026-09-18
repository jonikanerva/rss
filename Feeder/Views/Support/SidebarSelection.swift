import SwiftUI

/// Sidebar selection — either a folder aggregate or a specific category.
nonisolated enum SidebarSelection: Hashable, Sendable {
  case folder(String)
  case category(String)

  var isCategory: Bool {
    if case .category = self { return true }
    return false
  }
}

/// Flatten the folder groups and root categories into visual top-to-bottom
/// navigation order. This is where the rule lives that J/K navigation skips the
/// children of a collapsed folder.
nonisolated func sidebarNavigationItems(
  folderGroups: [(folderLabel: String, categoryLabels: [String])],
  rootCategoryLabels: [String],
  collapsedFolderLabels: Set<String>
) -> [SidebarSelection] {
  var items: [SidebarSelection] = []
  for group in folderGroups {
    items.append(.folder(group.folderLabel))
    guard !collapsedFolderLabels.contains(group.folderLabel) else { continue }
    for label in group.categoryLabels {
      items.append(.category(label))
    }
  }
  for label in rootCategoryLabels {
    items.append(.category(label))
  }
  return items
}

/// Fires `onChange` when any category's `folderLabel` changes. A modifier, so
/// the trigger stays out of `ContentView.body` and that body keeps
/// type-checking inside SwiftUI's limit.
struct CategoryFolderChangeTrigger: ViewModifier {
  let categoryFolderLabels: [String?]
  let onChange: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: categoryFolderLabels) {
      onChange()
    }
  }
}

/// Watches the mid-flight bump counters the engines publish and sets the
/// matching pending-bump flags, so the deferred drain modifiers coalesce them
/// into `entryRefreshVersion` ticks.
///
/// It must stay a leaf `View`, not a `ViewModifier`: reading those counters in
/// `ContentView.body` would put both `@Observable` counters in that body's
/// dependency graph, and each sync page and classification tick would
/// invalidate the whole split view. Reading them here re-evaluates only this
/// zero-size view.
struct MidFlightBumpRouter: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Binding
  var pendingSyncBump: Bool
  @Binding
  var pendingClassificationBump: Bool

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
      .onChange(of: syncEngine.lastPersistedPageVersion) {
        pendingSyncBump = true
      }
      .onChange(of: classificationEngine.batchProgressVersion) {
        pendingClassificationBump = true
      }
  }
}

/// Mounts `MidFlightBumpRouter` as an invisible background sibling. A
/// `ViewModifier`, so the call site stays one line and `ContentView.body` keeps
/// type-checking inside SwiftUI's limit.
struct MidFlightBumpRouterModifier: ViewModifier {
  @Binding
  var pendingSyncBump: Bool
  @Binding
  var pendingClassificationBump: Bool

  func body(content: Content) -> some View {
    content.background(
      MidFlightBumpRouter(
        pendingSyncBump: $pendingSyncBump,
        pendingClassificationBump: $pendingClassificationBump
      )
    )
  }
}

/// Drains a pending background refresh bump once the user is idle. It owns the
/// sleep and is re-keyed by selection identity and the pending flag, so each
/// selection change or new tick resets the window. With a selection the full
/// `dwell` applies; without one the shorter `idleThrottle` does, so an empty
/// category populates on a calm, coalesced cadence.
///
/// Shared by the classification drain, whose long dwell protects a selected row
/// from a membership reshuffle, and the sync-page drain, whose shorter dwell is
/// safe because new rows land at the top.
struct DeferredBumpDrainTrigger: ViewModifier {
  let key: String
  let dwell: Duration
  let idleThrottle: Duration
  let hasSelection: Bool
  @Binding
  var pendingBump: Bool
  let onDrain: () -> Void

  func body(content: Content) -> some View {
    content.task(id: key) {
      guard pendingBump else { return }
      try? await Task.sleep(for: hasSelection ? dwell : idleThrottle)
      guard !Task.isCancelled, pendingBump else { return }
      pendingBump = false
      onDrain()
    }
  }
}

/// Fires `onUnreadCountChange` whenever the cached snapshot's `totalUnread`
/// changes, which is how the owner learns to prune its optimistic
/// `pendingReadIDs` overlay. A modifier, so the `.onChange` stays out of
/// `ContentView.body`.
struct PendingReadPruneTrigger: ViewModifier {
  let unreadCount: Int
  let onUnreadCountChange: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: unreadCount) {
      onUnreadCountChange()
    }
  }
}

/// Refreshes the cached `UnreadCountsSnapshot` whenever `key` changes. The
/// fetch runs on the reader actor and MainActor receives only the resulting
/// `Sendable` value. `cutoffDate` is forwarded, so the sidebar snapshot and the
/// article-list fetch apply the same eligibility predicate. A modifier, so the
/// `.task(id:)` stays out of `ContentView.body`.
struct UnreadSnapshotRefreshTask: ViewModifier {
  let key: String
  let reader: DataReader?
  let cutoffDate: Date
  @Binding
  var snapshot: UnreadCountsSnapshot

  func body(content: Content) -> some View {
    content.task(id: key) {
      guard let reader else { return }
      let fresh = try? await reader.fetchUnreadCountsSnapshot(cutoffDate: cutoffDate)
      guard !Task.isCancelled, let fresh else { return }
      snapshot = fresh
    }
  }
}
