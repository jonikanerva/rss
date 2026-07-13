import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - ReadingSelection (issue #146 final fix)

/// Container-free pins for the nav model's pure transforms (the mirrors are
/// plain values) plus the single-writer resolve's memo contract (one
/// in-memory container for the `PersistentIdentifier`s).
@MainActor
struct ReadingSelectionTests {
  private static let items: [SidebarSelection] = [
    .folder("tech"), .category("apple"), .category("swift"), .category("world"),
  ]
  private static let names: [SidebarSelection: String] = [
    .folder("tech"): "Tech",
    .category("apple"): "Apple",
    .category("swift"): "Swift",
    .category("world"): "World News",
  ]

  private static func makeNav() -> ReadingSelection {
    let nav = ReadingSelection()
    nav.updateTaxonomy(items: items, displayNames: names)
    return nav
  }

  // MARK: - moveSelection

  @Test
  func moveForwardAdvancesInVisibleOrder() {
    let nav = Self.makeNav()
    nav.selection = .folder("tech")
    nav.moveSelection(by: 1)
    #expect(nav.selection == .category("apple"))
  }

  @Test
  func moveClampsAtTheEnds() {
    let nav = Self.makeNav()
    nav.selection = .category("world")
    nav.moveSelection(by: 1)
    #expect(nav.selection == .category("world"))
    nav.selection = .folder("tech")
    nav.moveSelection(by: -1)
    #expect(nav.selection == .folder("tech"))
  }

  @Test
  func nilSelectionFallsBackToFirstOrLast() {
    let nav = Self.makeNav()
    nav.moveSelection(by: 1)
    #expect(nav.selection == .folder("tech"))
    nav.selection = nil
    nav.moveSelection(by: -1)
    #expect(nav.selection == .category("world"))
  }

  @Test
  func emptyMirrorLeavesSelectionUntouched() {
    let nav = ReadingSelection()
    nav.selection = .category("apple")
    nav.moveSelection(by: 1)
    #expect(nav.selection == .category("apple"))
  }

  // MARK: - revalidateSelection

  @Test
  func staleSelectionFallsBackToFirstVisibleCategory() {
    let nav = Self.makeNav()
    nav.selection = .category("deleted")
    nav.revalidateSelection()
    #expect(nav.selection == .category("apple"))
  }

  @Test
  func validSelectionSurvivesRevalidation() {
    let nav = Self.makeNav()
    nav.selection = .category("swift")
    nav.revalidateSelection()
    #expect(nav.selection == .category("swift"))
  }

  @Test
  func collapsedFolderChildSurvivesRevalidation() {
    // The mirror's visible items exclude a collapsed folder's children, but
    // `displayNames` covers ALL taxonomy — a selection hidden by collapse
    // must stay valid (pre-split semantics: existence was checked against
    // the full query arrays, not visibility).
    let nav = ReadingSelection()
    nav.updateTaxonomy(
      items: [.folder("tech")],  // children collapsed away
      displayNames: Self.names
    )
    nav.selection = .category("apple")
    nav.revalidateSelection()
    #expect(nav.selection == .category("apple"))
  }

  @Test
  func folderAndCategoryLabelNamespacesStayDistinct() {
    // A category named like a deleted folder must not keep the folder
    // selection alive — the mirror keys existence by selection KIND.
    let nav = ReadingSelection()
    nav.updateTaxonomy(
      items: [.category("tech")],
      displayNames: [.category("tech"): "Tech (category)"]
    )
    nav.selection = .folder("tech")
    nav.revalidateSelection()
    #expect(nav.selection == .category("tech"))
  }

  // MARK: - resolveSelectedEntry (single writer + memo)

  @Test
  func resolveMaterialisesResetsAndMemoises() throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let context = ModelContext(container)
    let entry = Entry(
      feedbinEntryID: 42, title: "Resolve me", author: nil, url: "https://example.com/42",
      content: nil, summary: nil, extractedContentURL: nil, publishedAt: .now, createdAt: .now)
    context.insert(entry)
    try context.save()

    let nav = ReadingSelection()
    nav.articleViewMode = .reader
    nav.selectedEntryID = entry.persistentModelID
    nav.resolveSelectedEntry(in: context)
    #expect(nav.selectedEntry?.feedbinEntryID == 42)
    // The per-selection-commit view-mode reset lives inside the resolve.
    #expect(nav.articleViewMode == .web)

    // Memo no-op: same ID resolves to the identical object, and a view-mode
    // change made after the commit is NOT clobbered by a redundant call.
    nav.articleViewMode = .reader
    nav.resolveSelectedEntry(in: context)
    #expect(nav.articleViewMode == .reader)
    #expect(nav.selectedEntry?.feedbinEntryID == 42)

    // Clearing the ID clears the memo and resets the mode.
    nav.selectedEntryID = nil
    nav.resolveSelectedEntry(in: context)
    #expect(nav.selectedEntry == nil)
    #expect(nav.articleViewMode == .web)
  }

  // MARK: - Taxonomy mirror sync (displayName lookups)

  @Test
  func displayNameSyncReflectsRenames() {
    let nav = Self.makeNav()
    #expect(nav.displayNames[.category("world")] == "World News")
    var renamed = Self.names
    renamed[.category("world")] = "Global"
    nav.updateTaxonomy(items: Self.items, displayNames: renamed)
    #expect(nav.displayNames[.category("world")] == "Global")
    #expect(nav.sidebarItems == Self.items)
  }
}
