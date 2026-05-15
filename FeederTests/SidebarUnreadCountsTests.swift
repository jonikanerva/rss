import Foundation
import Testing

@testable import Feeder

// MARK: - unreadCountsByCategory

struct UnreadCountsByCategoryTests {
  @Test
  func aggregatesByLabel() {
    let labels = ["apple", "world_news", "apple", "apple", "world_news"]
    let counts = unreadCountsByCategory(labels)
    #expect(counts["apple"] == 3)
    #expect(counts["world_news"] == 2)
  }

  @Test
  func emptyLabelsAreIgnored() {
    let labels = ["", "apple", "", "apple", ""]
    let counts = unreadCountsByCategory(labels)
    #expect(counts.count == 1)
    #expect(counts["apple"] == 2)
    #expect(counts[""] == nil)
  }

  @Test
  func emptyInputReturnsEmptyDictionary() {
    let counts = unreadCountsByCategory([] as [String])
    #expect(counts.isEmpty)
  }

  @Test
  func missingLabelLookupReturnsZeroDefault() {
    let counts = unreadCountsByCategory(["apple"])
    #expect(counts["world_news", default: 0] == 0)
  }
}

// MARK: - unreadCountsByFolder

struct UnreadCountsByFolderTests {
  @Test
  func aggregatesByFolder() {
    let labels = ["technology", "technology", "world", "technology"]
    let counts = unreadCountsByFolder(labels)
    #expect(counts["technology"] == 3)
    #expect(counts["world"] == 1)
  }

  @Test
  func rootLevelEntriesAreNotCounted() {
    // Entries assigned to a root-level category have an empty primaryFolder
    // and must not contribute to any folder badge.
    let labels = ["", "", "technology", ""]
    let counts = unreadCountsByFolder(labels)
    #expect(counts["technology"] == 1)
    #expect(counts[""] == nil)
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
