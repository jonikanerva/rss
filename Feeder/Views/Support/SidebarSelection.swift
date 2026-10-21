import SwiftUI

/// Sidebar selection: the All Articles timeline, a folder aggregate, or a
/// specific category.
nonisolated enum SidebarSelection: Hashable, Sendable {
  case allArticles
  case folder(String)
  case category(String)

  var isCategory: Bool {
    if case .category = self { return true }
    return false
  }

  /// The articles that this row lists and marks as read.
  var entryScope: EntryScope {
    switch self {
    case .allArticles: .all
    case .folder(let label): .folder(label)
    case .category(let label): .category(label)
    }
  }
}

/// Flatten the sidebar rows into visual top-to-bottom navigation order: All
/// Articles, then the folder groups, then the root categories. This is where
/// the rule lives that J/K navigation skips the children of a collapsed folder.
nonisolated func sidebarNavigationItems(
  folderGroups: [(folderLabel: String, categoryLabels: [String])],
  rootCategoryLabels: [String],
  collapsedFolderLabels: Set<String>
) -> [SidebarSelection] {
  var items: [SidebarSelection] = [.allArticles]
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
