import Foundation

// MARK: - Drop planning types

/// Sendable snapshot of the fields of `Category` we need to compute a drop plan.
/// Pure-function callers hand these in so the plan helpers stay testable without
/// involving SwiftData. `sortOrder` is carried so `planMoveToFolder` can append
/// past the real max even when sort indexes have gaps (e.g. after a delete).
nonisolated struct CategorySnapshot: Sendable, Equatable {
  let label: String
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
  // Max-based, not count-based: tolerates gaps in peer sort orders (e.g. after
  // a delete). Falls back to -1 + 1 = 0 when the folder is empty.
  let maxOrder = existingInFolder.map(\.sortOrder).max() ?? -1
  return CategoryDropPlan(
    folderChanges: [.init(label: dragged, folderLabel: targetFolder, sortOrder: maxOrder + 1)],
    sortOrderUpdates: []
  )
}

/// Plan for inserting a category at a specific position inside a folder's child list.
/// Returns nil if the drop is disallowed (system category).
/// The dragged label's sort order is set via `folderChanges` when its folder is
/// changing, or via `sortOrderUpdates` when it stays in the same folder — never
/// both, so `batchUpdateCategoryFolderAndSortOrders` doesn't write it twice.
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

  let folderChanges: [CategoryDropPlan.FolderChange]
  let sortOrderUpdates: [CategoryDropPlan.SortOrderUpdate]
  if draggedCurrentFolder != targetFolder {
    folderChanges = [.init(label: dragged, folderLabel: targetFolder, sortOrder: insertAt)]
    sortOrderUpdates = children.enumerated().compactMap { index, label in
      label == dragged ? nil : .init(label: label, sortOrder: index)
    }
  } else {
    folderChanges = []
    sortOrderUpdates = children.enumerated().map { index, label in
      .init(label: label, sortOrder: index)
    }
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

  let folderChanges: [CategoryDropPlan.FolderChange]
  let finalSortOrderUpdates: [CategoryDropPlan.SortOrderUpdate]
  if draggedCurrentFolder != nil {
    folderChanges = [.init(label: dragged, folderLabel: nil, sortOrder: insertAt)]
    finalSortOrderUpdates = sortOrderUpdates.filter { $0.label != dragged }
  } else {
    folderChanges = []
    finalSortOrderUpdates = sortOrderUpdates
  }

  return CategoryDropPlan(folderChanges: folderChanges, sortOrderUpdates: finalSortOrderUpdates)
}
