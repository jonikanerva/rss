import Foundation
import Testing

@testable import Feeder

// MARK: - unreadCounts

struct UnreadCountsTests {
  @Test
  func aggregatesByLabel() {
    let labels = ["apple", "world_news", "apple", "apple", "world_news"]
    let counts = unreadCounts(in: labels)
    #expect(counts["apple"] == 3)
    #expect(counts["world_news"] == 2)
  }

  @Test
  func emptyLabelsAreIgnored() {
    // Empty labels stand in for entries that are unclassified (no category) or
    // assigned to a root-level category (no folder) — neither contributes to a
    // sidebar badge.
    let labels = ["", "apple", "", "apple", ""]
    let counts = unreadCounts(in: labels)
    #expect(counts.count == 1)
    #expect(counts["apple"] == 2)
    #expect(counts[""] == nil)
  }

  @Test
  func emptyInputReturnsEmptyDictionary() {
    let counts = unreadCounts(in: [] as [String])
    #expect(counts.isEmpty)
  }

  @Test
  func missingLabelLookupReturnsZeroDefault() {
    let counts = unreadCounts(in: ["apple"])
    #expect(counts["world_news", default: 0] == 0)
  }

  @Test
  func sameHelperAggregatesFolderLabels() {
    // The single helper serves both per-category and per-folder counting.
    let folders = ["technology", "technology", "world", "technology"]
    let counts = unreadCounts(in: folders)
    #expect(counts["technology"] == 3)
    #expect(counts["world"] == 1)
  }
}

// MARK: - sidebarNavigationItems

struct SidebarNavigationItemsTests {
  private static let groups: [(folderLabel: String, categoryLabels: [String])] = [
    (folderLabel: "technology", categoryLabels: ["apple", "playstation"]),
    (folderLabel: "media", categoryLabels: ["movies"]),
  ]
  private static let roots = ["world_news"]

  @Test
  func expandedFoldersExposeChildren() {
    let items = sidebarNavigationItems(
      folderGroups: Self.groups,
      rootCategoryLabels: Self.roots,
      collapsedFolderLabels: []
    )
    #expect(
      items == [
        .folder("technology"), .category("apple"), .category("playstation"),
        .folder("media"), .category("movies"),
        .category("world_news"),
      ])
  }

  @Test
  func collapsedFolderSkipsItsChildrenInNavigationOrder() {
    // Critical regression: J/K must not land on rows that are not visible in
    // the rendered source list. With "technology" collapsed, its child rows
    // disappear from the flat navigation list entirely.
    let items = sidebarNavigationItems(
      folderGroups: Self.groups,
      rootCategoryLabels: Self.roots,
      collapsedFolderLabels: ["technology"]
    )
    #expect(
      items == [
        .folder("technology"),
        .folder("media"), .category("movies"),
        .category("world_news"),
      ])
  }

  @Test
  func collapsedRootCategoriesAreUnaffected() {
    // Root-level categories are not nested under any folder, so the collapsed
    // set never hides them.
    let items = sidebarNavigationItems(
      folderGroups: [],
      rootCategoryLabels: ["world_news", "uncategorized"],
      collapsedFolderLabels: ["technology"]
    )
    #expect(items == [.category("world_news"), .category("uncategorized")])
  }
}

// MARK: - SidebarCollapsedFolders

struct SidebarCollapsedFoldersTests {
  @Test
  func defaultInitIsEmptyMeaningEverythingExpanded() {
    let store = SidebarCollapsedFolders()
    #expect(store.labels.isEmpty)
    #expect(!store.contains("technology"))
  }

  @Test
  func setCollapsedTogglesMembership() {
    var store = SidebarCollapsedFolders()
    store.set("technology", collapsed: true)
    #expect(store.contains("technology"))
    store.set("technology", collapsed: false)
    #expect(!store.contains("technology"))
  }

  @Test
  func rawValueRoundTrip() {
    var store = SidebarCollapsedFolders()
    store.set("technology", collapsed: true)
    store.set("world", collapsed: true)
    let raw = store.rawValue
    let restored = SidebarCollapsedFolders(rawValue: raw)
    #expect(restored?.labels == store.labels)
  }

  @Test
  func rawValueIsStableJSON() {
    // Deterministic ordering — array sorted before encoding — so two stores
    // with the same labels produce identical AppStorage strings.
    var a = SidebarCollapsedFolders()
    a.set("b", collapsed: true)
    a.set("a", collapsed: true)
    var b = SidebarCollapsedFolders()
    b.set("a", collapsed: true)
    b.set("b", collapsed: true)
    #expect(a.rawValue == b.rawValue)
  }

  @Test
  func invalidRawValueReturnsNil() {
    #expect(SidebarCollapsedFolders(rawValue: "not-json") == nil)
  }
}
