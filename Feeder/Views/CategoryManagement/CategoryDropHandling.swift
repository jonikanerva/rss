import Foundation

// MARK: - Drop planning types

/// Sendable snapshot of the fields of `Category` we need to compute a drop plan.
/// Pure-function callers hand these in so the plan helpers stay testable without
/// involving SwiftData.
nonisolated struct CategorySnapshot: Sendable, Equatable {
  let label: String
  let folderLabel: String?
  let sortOrder: Int
}

/// Pending DataWriter call produced by a drop plan. Empty arrays indicate
/// "no writes needed" (e.g. dropped on the same folder at the same position).
nonisolated struct CategoryDropPlan: Sendable, Equatable {
  struct FolderChange: Sendable, Equatable {
    let label: String
    let folderLabel: String?
    let sortOrder: Int
  }
  struct SortOrderUpdate: Sendable, Equatable {
    let label: String
    let sortOrder: Int
  }

  let folderChanges: [FolderChange]
  let sortOrderUpdates: [SortOrderUpdate]

  static let empty = CategoryDropPlan(folderChanges: [], sortOrderUpdates: [])
}

// MARK: - Pure planners

/// Plan for dropping a category directly on a folder header (append to end).
/// Returns nil if the drop is disallowed (system category).
nonisolated func planMoveToFolder(
  dragged: String,
  targetFolder: String,
  existingInFolder: [CategorySnapshot]
) -> CategoryDropPlan? {
  guard dragged != uncategorizedLabel else { return nil }
  let maxOrder = existingInFolder.map(\.sortOrder).max() ?? -1
  return CategoryDropPlan(
    folderChanges: [.init(label: dragged, folderLabel: targetFolder, sortOrder: maxOrder + 1)],
    sortOrderUpdates: []
  )
}

/// Plan for inserting a category at a specific position inside a folder's child list.
/// Returns nil if the drop is disallowed (system category).
nonisolated func planInsertInFolder(
  dragged: String,
  draggedCurrentFolder: String?,
  targetFolder: String,
  position: Int,
  existingInFolder: [CategorySnapshot]
) -> CategoryDropPlan? {
  guard dragged != uncategorizedLabel else { return nil }

  var children = existingInFolder.map(\.label)
  children.removeAll { $0 == dragged }
  let insertAt = min(position, children.count)
  children.insert(dragged, at: insertAt)

  let sortOrderUpdates = children.enumerated().map { index, label in
    CategoryDropPlan.SortOrderUpdate(label: label, sortOrder: index)
  }

  var folderChanges: [CategoryDropPlan.FolderChange] = []
  if draggedCurrentFolder != targetFolder {
    folderChanges.append(.init(label: dragged, folderLabel: targetFolder, sortOrder: insertAt))
  }

  return CategoryDropPlan(folderChanges: folderChanges, sortOrderUpdates: sortOrderUpdates)
}

/// Plan for dropping a category into the root list at a specific position.
/// Returns nil if the drop is disallowed (system category).
nonisolated func planMoveToRoot(
  dragged: String,
  draggedCurrentFolder: String?,
  position: Int,
  existingAtRoot: [CategorySnapshot]
) -> CategoryDropPlan? {
  guard dragged != uncategorizedLabel else { return nil }

  var rootLabels = existingAtRoot.map(\.label)
  rootLabels.removeAll { $0 == dragged }
  let insertAt = min(position, rootLabels.count)
  rootLabels.insert(dragged, at: insertAt)

  let sortOrderUpdates = rootLabels.enumerated().map { index, label in
    CategoryDropPlan.SortOrderUpdate(label: label, sortOrder: index)
  }

  var folderChanges: [CategoryDropPlan.FolderChange] = []
  if draggedCurrentFolder != nil {
    folderChanges.append(.init(label: dragged, folderLabel: nil, sortOrder: insertAt))
  }

  return CategoryDropPlan(folderChanges: folderChanges, sortOrderUpdates: sortOrderUpdates)
}
