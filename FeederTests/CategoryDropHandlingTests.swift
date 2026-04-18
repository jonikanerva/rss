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
      .init(label: "ai", sortOrder: 0),
      .init(label: "apple", sortOrder: 1),
    ]
    let plan = planMoveToFolder(
      dragged: "rivian", targetFolder: "tech", existingInFolder: existing
    )
    #expect(plan?.folderChanges.first?.sortOrder == 2)
  }

  @Test
  func moveToFolderTolearatesGaps() {
    // Deletes can leave gaps ([0, 2, 5]); append must land past the real max,
    // not at `count`. Regression guard for the count-based shortcut.
    let existing: [CategorySnapshot] = [
      .init(label: "ai", sortOrder: 0),
      .init(label: "apple", sortOrder: 2),
      .init(label: "tesla", sortOrder: 5),
    ]
    let plan = planMoveToFolder(
      dragged: "rivian", targetFolder: "tech", existingInFolder: existing
    )
    #expect(plan?.folderChanges.first?.sortOrder == 6)
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
  func insertAtHeadOfFolderExcludesDraggedFromSortOrderUpdates() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", sortOrder: 0),
      .init(label: "apple", sortOrder: 1),
    ]
    let plan = planInsertInFolder(
      dragged: "rivian", draggedCurrentFolder: nil,
      targetFolder: "tech", position: 0, existingInFolder: existing
    )
    // Dragged label's sort order lives on folderChanges (insertAt = 0),
    // so sortOrderUpdates only covers the peers at their shifted positions.
    #expect(plan?.folderChanges.count == 1)
    #expect(plan?.folderChanges.first?.sortOrder == 0)
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["ai", "apple"])
  }

  @Test
  func insertPositionClampsToEnd() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", sortOrder: 0)
    ]
    let plan = planInsertInFolder(
      dragged: "rivian", draggedCurrentFolder: nil,
      targetFolder: "tech", position: 999, existingInFolder: existing
    )
    #expect(plan?.folderChanges.first?.sortOrder == 1)
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["ai"])
  }

  @Test
  func insertWithinSameFolderSkipsFolderChangeAndReordersAll() {
    let existing: [CategorySnapshot] = [
      .init(label: "ai", sortOrder: 0),
      .init(label: "apple", sortOrder: 1),
    ]
    // apple moves from position 1 to 0 within tech — no folder change, full re-order
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
  func moveToRootReordersPeersAndClearsFolder() {
    let existing: [CategorySnapshot] = [
      .init(label: "science", sortOrder: 0),
      .init(label: "world_news", sortOrder: 1),
    ]
    let plan = planMoveToRoot(
      dragged: "apple", draggedCurrentFolder: "tech",
      position: 1, existingAtRoot: existing
    )
    // Dragged's sortOrder comes from folderChanges; updates exclude it.
    #expect(plan?.folderChanges.count == 1)
    #expect(plan?.folderChanges.first?.sortOrder == 1)
    #expect(plan?.folderChanges.first?.folderLabel == nil)
    let order = plan?.sortOrderUpdates.map(\.label) ?? []
    #expect(order == ["science", "world_news"])
  }

  @Test
  func moveToRootFromRootSkipsFolderChange() {
    let existing: [CategorySnapshot] = [
      .init(label: "science", sortOrder: 0),
      .init(label: "world_news", sortOrder: 1),
    ]
    // science already at root — full re-order, no folder change
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
