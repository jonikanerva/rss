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
