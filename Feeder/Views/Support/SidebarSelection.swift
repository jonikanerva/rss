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
/// `entryRefreshVersion` ticks. Extracted into a modifier so the two
/// `.onChange` observers stay out of `ContentView.body` and the body keeps
/// type-checking inside SwiftUI's reasonable-time limit.
struct MidFlightBumpRouter: ViewModifier {
  let syncPageVersion: Int
  let classificationBatchVersion: Int
  @Binding
  var pendingSyncBump: Bool
  @Binding
  var pendingClassificationBump: Bool

  func body(content: Content) -> some View {
    content
      .onChange(of: syncPageVersion) {
        pendingSyncBump = true
      }
      .onChange(of: classificationBatchVersion) {
        pendingClassificationBump = true
      }
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
