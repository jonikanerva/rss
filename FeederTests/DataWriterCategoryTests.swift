import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - DataWriter Category Tests

struct DataWriterCategoryTests {
  // MARK: - Helpers

  private func makeWriter() async throws -> DataWriter {
    try await DataWriterTestSupport.makeWriter()
  }

  private func seedHierarchy(_ writer: DataWriter) async throws {
    try await writer.addCategory(
      label: "technology", displayName: "Technology",
      description: "Tech news", sortOrder: 0
    )
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple news", sortOrder: 0, parentLabel: "technology"
    )
    try await writer.addCategory(
      label: "ai", displayName: "AI",
      description: "AI news", sortOrder: 1, parentLabel: "technology"
    )
    try await writer.addCategory(
      label: "gaming", displayName: "Gaming",
      description: "Gaming news", sortOrder: 1
    )
    try await writer.addCategory(
      label: "ps5", displayName: "PlayStation 5",
      description: "PS5 news", sortOrder: 0, parentLabel: "gaming"
    )
  }

  // MARK: - addCategory

  @Test
  func addTopLevelCategory() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Tech news", sortOrder: 0
    )
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.count == 1)
    #expect(defs[0].label == "tech")
    #expect(defs[0].isTopLevel == true)
    #expect(defs[0].parentLabel == nil)
  }

  @Test
  func addChildCategory() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Tech news", sortOrder: 0
    )
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple news", sortOrder: 0, parentLabel: "tech"
    )
    let defs = try await writer.fetchCategoryDefinitions()
    let child = defs.first { $0.label == "apple" }
    #expect(child != nil)
    #expect(child?.parentLabel == "tech")
    #expect(child?.isTopLevel == false)
  }

  // MARK: - deleteCategory (cascade)

  @Test
  func deleteTopLevelCascadesChildren() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    try await writer.deleteCategory(label: "technology")

    let defs = try await writer.fetchCategoryDefinitions()
    let labels = Set(defs.map(\.label))
    #expect(!labels.contains("technology"))
    #expect(!labels.contains("apple"))
    #expect(!labels.contains("ai"))
    #expect(labels.contains("gaming"))
    #expect(labels.contains("ps5"))
  }

  @Test
  func deleteChildDoesNotAffectParentOrSiblings() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    try await writer.deleteCategory(label: "apple")

    let defs = try await writer.fetchCategoryDefinitions()
    let labels = Set(defs.map(\.label))
    #expect(labels.contains("technology"))
    #expect(labels.contains("ai"))
    #expect(!labels.contains("apple"))
  }

  @Test
  func deleteTopLevelWithNoChildrenIsClean() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "world", displayName: "World",
      description: "World news", sortOrder: 0
    )
    try await writer.deleteCategory(label: "world")

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.isEmpty)
  }

  // MARK: - childCategoryNames

  @Test
  func childCategoryNamesReturnsCorrectNames() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    let names = try await writer.childCategoryNames(for: "technology")
    #expect(names.count == 2)
    #expect(names.contains("Apple"))
    #expect(names.contains("AI"))
  }

  @Test
  func childCategoryNamesReturnsEmptyForLeaf() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    let names = try await writer.childCategoryNames(for: "apple")
    #expect(names.isEmpty)
  }

  @Test
  func childCategoryNamesReturnsEmptyForNonexistent() async throws {
    let writer = try await makeWriter()
    let names = try await writer.childCategoryNames(for: "nonexistent")
    #expect(names.isEmpty)
  }

  // MARK: - updateCategoryFields

  @Test
  func updateCategoryFieldsChangesNameAndDescription() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Old desc", sortOrder: 0
    )
    try await writer.updateCategoryFields(
      label: "tech", displayName: "Technology", description: "New desc"
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let cat = defs.first { $0.label == "tech" }
    #expect(cat?.description == "New desc")
  }

  // MARK: - updateCategorySortOrders

  @Test
  func updateSortOrdersReorders() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "a", displayName: "A", description: "A", sortOrder: 0
    )
    try await writer.addCategory(
      label: "b", displayName: "B", description: "B", sortOrder: 1
    )
    try await writer.updateCategorySortOrders([
      (label: "a", sortOrder: 1),
      (label: "b", sortOrder: 0),
    ])

    let orderA = try await writer.fetchCategorySortOrder(label: "a")
    let orderB = try await writer.fetchCategorySortOrder(label: "b")
    #expect(orderA == 1)
    #expect(orderB == 0)
  }

  // MARK: - seedDefaultCategories

  @Test
  func seedDefaultCategoriesCreatesAll() async throws {
    let writer = try await makeWriter()
    let defaults: [(label: String, displayName: String, description: String, sortOrder: Int, parentLabel: String?)] = [
      ("tech", "Tech", "Tech news", 0, nil),
      ("gaming", "Gaming", "Games", 1, nil),
      ("apple", "Apple", "Apple news", 0, "tech"),
    ]
    try await writer.seedDefaultCategories(defaults)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.count == 3)

    let topLevel = defs.filter(\.isTopLevel)
    #expect(topLevel.count == 2)

    let children = defs.filter { !$0.isTopLevel }
    #expect(children.count == 1)
    #expect(children[0].parentLabel == "tech")
  }

  // MARK: - updateCategoryHierarchy

  @Test
  func promoteChildToTopLevel() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    try await writer.updateCategoryHierarchy(
      label: "apple", parentLabel: nil,
      depth: 0, isTopLevel: true, sortOrder: 5
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let apple = defs.first { $0.label == "apple" }
    #expect(apple?.isTopLevel == true)
    #expect(apple?.parentLabel == nil)
  }

  @Test
  func demoteTopLevelToChild() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)

    try await writer.updateCategoryHierarchy(
      label: "gaming", parentLabel: "technology",
      depth: 1, isTopLevel: false, sortOrder: 2
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let gaming = defs.first { $0.label == "gaming" }
    #expect(gaming?.isTopLevel == false)
    #expect(gaming?.parentLabel == "technology")
  }

  @Test
  func demoteParentOrphansChildrenCanBePromoted() async throws {
    let writer = try await makeWriter()
    try await seedHierarchy(writer)
    // Hierarchy: technology -> [apple, ai], gaming -> [ps5]

    // Demote "technology" under "gaming" — simulating drag
    try await writer.updateCategoryHierarchy(
      label: "technology", parentLabel: "gaming",
      depth: 1, isTopLevel: false, sortOrder: 1
    )
    // Promote orphaned children (apple, ai) to top-level
    try await writer.updateCategoryHierarchy(
      label: "apple", parentLabel: nil,
      depth: 0, isTopLevel: true, sortOrder: 2
    )
    try await writer.updateCategoryHierarchy(
      label: "ai", parentLabel: nil,
      depth: 0, isTopLevel: true, sortOrder: 3
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let apple = defs.first { $0.label == "apple" }
    let ai = defs.first { $0.label == "ai" }
    let tech = defs.first { $0.label == "technology" }
    #expect(apple?.isTopLevel == true)
    #expect(apple?.parentLabel == nil)
    #expect(ai?.isTopLevel == true)
    #expect(ai?.parentLabel == nil)
    #expect(tech?.isTopLevel == false)
    #expect(tech?.parentLabel == "gaming")
  }

  // MARK: - System category protection

  @Test
  func deleteSystemCategoryIsNoOp() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    // Manually set isSystem since addCategory doesn't support it
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    try await writer.deleteCategory(label: uncategorizedLabel)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  @Test
  func systemCategoryCannotBecomeChild() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Tech", sortOrder: 0
    )
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    try await writer.updateCategoryHierarchy(
      label: uncategorizedLabel, parentLabel: "tech",
      depth: 1, isTopLevel: false, sortOrder: 0
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let uncat = defs.first { $0.label == uncategorizedLabel }
    #expect(uncat?.isTopLevel == true)
    #expect(uncat?.parentLabel == nil)
  }

  @Test
  func categoryCannotBecomeChildOfSystem() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Tech", sortOrder: 0
    )
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    try await writer.updateCategoryHierarchy(
      label: "tech", parentLabel: uncategorizedLabel,
      depth: 1, isTopLevel: false, sortOrder: 0
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let tech = defs.first { $0.label == "tech" }
    #expect(tech?.isTopLevel == true)
    #expect(tech?.parentLabel == nil)
  }
}
