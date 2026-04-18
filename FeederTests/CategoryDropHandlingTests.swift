import Testing

@testable import Feeder

struct CategoryDropHandlingTests {
  // MARK: - planMoveToFolder

  @Test
  func moveToEmptyFolderAppendsAtZero() {
    let plan = planMoveToFolder(dragged: "apple", targetFolder: "tech", existingInFolder: [])
    #expect(plan?.folderChanges.count == 1)
    #expect(plan?.folderChanges.first?.label == "apple")
    #expect(plan?.folderChanges.first?.folderLabel == "tech")
    #expect(plan?.folderChanges.first?.sortOrder == 0)
    #expect(plan?.sortOrderUpdates.isEmpty == true)
  }

  @Test
  func moveToNonEmptyFolderAppendsAfterMax() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", folderLabel: "tech", sortOrder: 0),
      .init(label: "apple", folderLabel: "tech", sortOrder: 1),
    ]
    let plan = planMoveToFolder(
      dragged: "rivian", targetFolder: "tech", existingInFolder: existing
    )
    #expect(plan?.folderChanges.first?.sortOrder == 2)
  }

  @Test
  func moveToFolderRejectsUncategorized() {
    let plan = planMoveToFolder(
      dragged: uncategorizedLabel, targetFolder: "tech", existingInFolder: []
    )
    #expect(plan == nil)
  }

  // MARK: - planInsertInFolder

  @Test
  func insertAtHeadOfFolder() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", folderLabel: "tech", sortOrder: 0),
      .init(label: "apple", folderLabel: "tech", sortOrder: 1),
    ]
    let plan = planInsertInFolder(
      dragged: "rivian", draggedCurrentFolder: nil,
      targetFolder: "tech", position: 0, existingInFolder: existing
    )
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["rivian", "ai", "apple"])
    #expect(plan?.folderChanges.first?.folderLabel == "tech")
  }

  @Test
  func insertPositionClampsToEnd() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", folderLabel: "tech", sortOrder: 0)
    ]
    let plan = planInsertInFolder(
      dragged: "rivian", draggedCurrentFolder: nil,
      targetFolder: "tech", position: 999, existingInFolder: existing
    )
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["ai", "rivian"])
  }

  @Test
  func insertWithinSameFolderSkipsFolderChange() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", folderLabel: "tech", sortOrder: 0),
      .init(label: "apple", folderLabel: "tech", sortOrder: 1),
    ]
    // apple moves from position 1 to 0 within tech — no folder change expected
    let plan = planInsertInFolder(
      dragged: "apple", draggedCurrentFolder: "tech",
      targetFolder: "tech", position: 0, existingInFolder: existing
    )
    #expect(plan?.folderChanges.isEmpty == true)
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["apple", "ai"])
  }

  @Test
  func insertRejectsUncategorized() {
    let plan = planInsertInFolder(
      dragged: uncategorizedLabel, draggedCurrentFolder: nil,
      targetFolder: "tech", position: 0, existingInFolder: []
    )
    #expect(plan == nil)
  }

  // MARK: - planMoveToRoot

  @Test
  func moveToRootReordersAndClearsFolder() {
    let existing: [CategorySnapshot] = [
      .init(label: "science", folderLabel: nil, sortOrder: 0),
      .init(label: "world_news", folderLabel: nil, sortOrder: 1),
    ]
    let plan = planMoveToRoot(
      dragged: "apple", draggedCurrentFolder: "tech",
      position: 1, existingAtRoot: existing
    )
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["science", "apple", "world_news"])
    #expect(plan?.folderChanges.first?.folderLabel == nil)
  }

  @Test
  func moveToRootFromRootSkipsFolderChange() {
    let existing: [CategorySnapshot] = [
      .init(label: "science", folderLabel: nil, sortOrder: 0),
      .init(label: "world_news", folderLabel: nil, sortOrder: 1),
    ]
    // science already at root — only reorder
    let plan = planMoveToRoot(
      dragged: "science", draggedCurrentFolder: nil,
      position: 1, existingAtRoot: existing
    )
    #expect(plan?.folderChanges.isEmpty == true)
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["world_news", "science"])
  }

  @Test
  func moveToRootRejectsUncategorized() {
    let plan = planMoveToRoot(
      dragged: uncategorizedLabel, draggedCurrentFolder: nil,
      position: 0, existingAtRoot: []
    )
    #expect(plan == nil)
  }
}
