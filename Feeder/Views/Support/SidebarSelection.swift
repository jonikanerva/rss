import SwiftUI

/// Sidebar selection — either a folder aggregate or a specific category.
enum SidebarSelection: Hashable {
  case folder(String)
  case category(String)

  var isCategory: Bool {
    if case .category = self { return true }
    return false
  }
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

/// Drains a pending classification refresh bump once the user is idle.
/// Owns the dwell `Task.sleep` so the bump fires when a list rebuild will not
/// disrupt the user — re-keyed by selection identity and the pending flag so
/// each selection change or new batch resets the dwell window. Extracted
/// into a modifier so the task closure stays out of ContentView.body and the
/// body keeps type-checking inside SwiftUI's reasonable-time limit.
struct ClassificationBumpDrainTrigger: ViewModifier {
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
