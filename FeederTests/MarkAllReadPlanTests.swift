import Testing

@testable import Feeder

/// The pure plan behind Mark All as Read: ⇧A, the toolbar, and the Article
/// menu pass the current selection as the target, and a sidebar row menu
/// passes its own row.
@Suite("Mark-all-read plan (pure)")
struct MarkAllReadPlanTests {
  /// Folder `tech` holds `apple` and `google`. `world` is a root category.
  private static let snapshot = UnreadCountsSnapshot(
    categoryCounts: ["apple": 2, "google": 1, "world": 2],
    folderCounts: ["tech": 3],
    unreadFeedbinEntryIDs: [1, 2, 3, 4, 5],
    unreadIDByCategory: ["apple": [1, 2], "google": [3], "world": [4, 5]],
    unreadIDByFolder: ["tech": [1, 2, 3]],
    totalUnread: 5
  )

  private func plan(
    for target: SidebarSelection, currentSelection: SidebarSelection?
  ) -> MarkAllReadPlan {
    markAllReadPlan(for: target, currentSelection: currentSelection, snapshot: Self.snapshot)
  }

  // MARK: - Target is the current selection

  @Test("the selected category as the target clears the article selection, like ⇧A")
  func selectedCategoryClearsArticleSelection() {
    #expect(
      plan(for: .category("apple"), currentSelection: .category("apple"))
        == MarkAllReadPlan(
          markTarget: .category("apple"), optimisticIDs: [1, 2], clearsArticleSelection: true))
  }

  @Test("the selected folder as the target clears the article selection, like ⇧A")
  func selectedFolderClearsArticleSelection() {
    #expect(
      plan(for: .folder("tech"), currentSelection: .folder("tech"))
        == MarkAllReadPlan(
          markTarget: .folder("tech"), optimisticIDs: [1, 2, 3], clearsArticleSelection: true))
  }

  // MARK: - Target is another row

  @Test("a root category that is not selected marks only that category and keeps the selection")
  func unselectedRootCategoryKeepsSelection() {
    #expect(
      plan(for: .category("world"), currentSelection: .category("apple"))
        == MarkAllReadPlan(
          markTarget: .category("world"), optimisticIDs: [4, 5], clearsArticleSelection: false))
  }

  @Test("a category inside a folder marks only that category, not its folder")
  func categoryInsideFolderMarksOnlyThatCategory() {
    #expect(
      plan(for: .category("google"), currentSelection: .category("world"))
        == MarkAllReadPlan(
          markTarget: .category("google"), optimisticIDs: [3], clearsArticleSelection: false))
  }

  @Test("a folder marks every category in it, also when its row is collapsed")
  func folderMarksEveryCategoryInIt() throws {
    // A collapsed folder hides its category rows. The plan has no expansion
    // input, so it still marks the whole folder axis.
    let visibleRows = sidebarNavigationItems(
      folderGroups: [(folderLabel: "tech", categoryLabels: ["apple", "google"])],
      rootCategoryLabels: ["world"],
      collapsedFolderLabels: ["tech"])
    try #require(visibleRows == [.folder("tech"), .category("world")])

    #expect(
      plan(for: .folder("tech"), currentSelection: .category("world"))
        == MarkAllReadPlan(
          markTarget: .folder("tech"), optimisticIDs: [1, 2, 3], clearsArticleSelection: false))
  }

  // MARK: - Nested targets

  @Test("a folder that holds the selected category keeps the article selection")
  func folderHoldingSelectedCategoryKeepsSelection() {
    #expect(
      plan(for: .folder("tech"), currentSelection: .category("apple"))
        == MarkAllReadPlan(
          markTarget: .folder("tech"), optimisticIDs: [1, 2, 3], clearsArticleSelection: false))
  }

  @Test("a category inside the selected folder keeps the article selection")
  func categoryInsideSelectedFolderKeepsSelection() {
    #expect(
      plan(for: .category("apple"), currentSelection: .folder("tech"))
        == MarkAllReadPlan(
          markTarget: .category("apple"), optimisticIDs: [1, 2], clearsArticleSelection: false))
  }

  // MARK: - Edges

  @Test("a target with no unread IDs in the snapshot still marks the target")
  func targetMissingFromSnapshotStillMarks() {
    #expect(
      plan(for: .category("science"), currentSelection: .category("apple"))
        == MarkAllReadPlan(
          markTarget: .category("science"), optimisticIDs: [], clearsArticleSelection: false))
  }

  @Test("with no sidebar selection the plan never clears the article selection")
  func noSidebarSelectionKeepsArticleSelection() {
    #expect(plan(for: .category("apple"), currentSelection: nil).clearsArticleSelection == false)
    #expect(plan(for: .folder("tech"), currentSelection: nil).clearsArticleSelection == false)
  }
}
