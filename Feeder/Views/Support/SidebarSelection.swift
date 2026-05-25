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

/// Flatten `(folder, [categoryLabel])` groups plus root-level category labels
/// into the visual top-to-bottom navigation order, honouring which folders are
/// collapsed.
///
/// Pure helper extracted from `ContentView.sidebarItems` so the behaviour is
/// unit-testable without spinning up a SwiftUI host: the rule that J/K
/// navigation must skip the children of a collapsed folder is enforced here.
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

/// Fires `onChange` when any category's `folderLabel` changes. Extracted into
/// a modifier so the category-folder-move refetch trigger doesn't push
/// ContentView.body past the type-checker's reasonable-time limit.
struct CategoryFolderChangeTrigger: ViewModifier {
  let categoryFolderLabels: [String?]
  let onChange: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: categoryFolderLabels) {
      onChange()
    }
  }
}

/// Mid-flight refresh router. Watches the monotonic bump counters published
/// by `SyncEngine` (per persisted page) and `ClassificationEngine` (per
/// throttled progress snapshot), and sets the matching pending-bump flags
/// so the deferred drain modifiers can coalesce them into
/// `entryRefreshVersion` ticks.
///
/// Lives as a leaf `View` (rendered as a zero-size `Color.clear`) instead
/// of a `ViewModifier` — `ContentView.body` would otherwise read
/// `syncEngine.lastPersistedPageVersion` and
/// `classificationEngine.batchProgressVersion` to pass them in, which made
/// every body re-eval depend on both `@Observable` counters. Sync ticks
/// these per persisted page (~once a second during sync) and classification
/// ticks them per throttled progress snapshot (~every 200 ms during a batch),
/// so the outer body was being invalidated continuously and re-fetching the
/// (now-cached) unread snapshot on every tick. By reading the counters
/// inside this leaf's own body, only this zero-size view re-evaluates —
/// `ContentView.body` stays out of the dependency graph entirely.
///
/// Hosted by `ContentView` via `.background(MidFlightBumpRouter(...))` so
/// the leaf participates in the view hierarchy and observes the
/// `@Environment` engines, but contributes no visible chrome.
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

/// Mounts `MidFlightBumpRouter` as an invisible `.background` sibling of the
/// host view. Kept as a `ViewModifier` so `ContentView.body`'s modifier
/// chain stays inside SwiftUI's type-checker reasonable-time limit — the
/// leaf-view hoisting only matters for which view re-evaluates on engine
/// counter bumps; the call-site shape stays a single `.modifier(...)` line.
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

/// Drains a pending background refresh bump once the user is idle.
/// Owns the dwell `Task.sleep` so the bump fires when a list rebuild will not
/// disrupt the user — re-keyed by selection identity and the pending flag so
/// each selection change or new background tick resets the dwell window.
/// Extracted into a modifier so the task closure stays out of
/// `ContentView.body` and the body keeps type-checking inside SwiftUI's
/// reasonable-time limit.
///
/// Reused by both the classification-batch drain (long dwell — finished
/// batches reshuffle category membership and may move the selected row out
/// of view) and the sync-page drain (shorter dwell — newly-inserted entries
/// land at the top via stable-ID diffing and do not move the selected row).
struct DeferredBumpDrainTrigger: ViewModifier {
  let key: String
  let dwell: Duration
  let hasSelection: Bool
  @Binding
  var pendingBump: Bool
  let onDrain: () -> Void

  func body(content: Content) -> some View {
    content.task(id: key) {
      guard pendingBump else { return }
      if !hasSelection {
        pendingBump = false
        onDrain()
        return
      }
      try? await Task.sleep(for: dwell)
      guard !Task.isCancelled, pendingBump else { return }
      pendingBump = false
      onDrain()
    }
  }
}

/// Fires `onUnreadCountChange` whenever the cached unread snapshot's
/// `totalUnread` changes — typically right after a `DataWriter` save
/// (mark-read / mark-all-read / sync) propagates via the snapshot refresh
/// task. The owner uses this hook to prune its optimistic `pendingReadIDs`
/// overlay back down to the IDs still present in the live unread set.
/// Extracted into a modifier so the prune `.onChange` stays out of
/// `ContentView.body` and the body keeps type-checking inside SwiftUI's
/// reasonable-time limit.
struct PendingReadPruneTrigger: ViewModifier {
  let unreadCount: Int
  let onUnreadCountChange: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: unreadCount) {
      onUnreadCountChange()
    }
  }
}

/// Refreshes the cached `UnreadCountsSnapshot` whenever `key` changes.
/// Re-keyed on `entryRefreshVersion` plus folder/category counts so taxonomy
/// edits also trigger a refresh. The fetch runs on the `DataWriter` actor —
/// MainActor only receives the resulting Sendable DTO. Extracted into a
/// modifier so the `.task(id:)` stays out of `ContentView.body` and the body
/// keeps type-checking inside SwiftUI's reasonable-time limit.
struct UnreadSnapshotRefreshTask: ViewModifier {
  let key: String
  let writer: DataWriter?
  @Binding
  var snapshot: UnreadCountsSnapshot

  func body(content: Content) -> some View {
    content.task(id: key) {
      guard let writer else { return }
      let fresh = try? await writer.fetchUnreadCountsSnapshot()
      guard !Task.isCancelled, let fresh else { return }
      snapshot = fresh
    }
  }
}
