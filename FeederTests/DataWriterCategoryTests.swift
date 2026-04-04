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

  private func seedFoldersAndCategories(_ writer: DataWriter) async throws {
    try await writer.addFolder(label: "technology", displayName: "Technology", sortOrder: 0)
    try await writer.addFolder(label: "gaming", displayName: "Gaming", sortOrder: 1)
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple news", sortOrder: 0, folderLabel: "technology"
    )
    try await writer.addCategory(
      label: "ai", displayName: "AI",
      description: "AI news", sortOrder: 1, folderLabel: "technology"
    )
    try await writer.addCategory(
      label: "ps5", displayName: "PlayStation 5",
      description: "PS5 news", sortOrder: 0, folderLabel: "gaming"
    )
    try await writer.addCategory(
      label: "science", displayName: "Science",
      description: "Science news", sortOrder: 0
    )
  }

  // MARK: - addCategory

  @Test
  func addRootCategory() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "tech", displayName: "Tech",
      description: "Tech news", sortOrder: 0
    )
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.count == 1)
    #expect(defs[0].label == "tech")
    #expect(defs[0].folderLabel == nil)
  }

  @Test
  func addCategoryInFolder() async throws {
    let writer = try await makeWriter()
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple news", sortOrder: 0, folderLabel: "tech"
    )
    let defs = try await writer.fetchCategoryDefinitions()
    let child = defs.first { $0.label == "apple" }
    #expect(child != nil)
    #expect(child?.folderLabel == "tech")
  }

  // MARK: - deleteCategory

  @Test
  func deleteCategoryIsSimple() async throws {
    let writer = try await makeWriter()
    try await seedFoldersAndCategories(writer)

    try await writer.deleteCategory(label: "apple")

    let defs = try await writer.fetchCategoryDefinitions()
    let labels = Set(defs.map(\.label))
    #expect(!labels.contains("apple"))
    #expect(labels.contains("ai"))
    #expect(labels.contains("ps5"))
    #expect(labels.contains("science"))
  }

  @Test
  func deleteRootCategoryIsClean() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: "world", displayName: "World",
      description: "World news", sortOrder: 0
    )
    try await writer.deleteCategory(label: "world")

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.isEmpty)
  }

  // MARK: - Folder CRUD

  @Test
  func addFolder() async throws {
    let writer = try await makeWriter()
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    // Verify folder exists by adding a category to it
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple", sortOrder: 0, folderLabel: "tech"
    )
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.first?.folderLabel == "tech")
  }

  @Test
  func deleteFolderMovesCategoriestoRoot() async throws {
    let writer = try await makeWriter()
    try await seedFoldersAndCategories(writer)

    try await writer.deleteFolder(label: "technology")

    let defs = try await writer.fetchCategoryDefinitions()
    let apple = defs.first { $0.label == "apple" }
    let ai = defs.first { $0.label == "ai" }
    #expect(apple?.folderLabel == nil)
    #expect(ai?.folderLabel == nil)
    // Categories in gaming folder should be unaffected
    let ps5 = defs.first { $0.label == "ps5" }
    #expect(ps5?.folderLabel == "gaming")
  }

  @Test
  func updateFolderFields() async throws {
    let writer = try await makeWriter()
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    try await writer.updateFolderFields(label: "tech", displayName: "Technology")
    // Indirectly verify — folder still usable
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple", sortOrder: 0, folderLabel: "tech"
    )
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.first?.folderLabel == "tech")
  }

  // MARK: - moveCategoryToFolder

  @Test
  func moveCategoryToFolder() async throws {
    let writer = try await makeWriter()
    try await seedFoldersAndCategories(writer)

    // Move science (root) into gaming folder
    try await writer.moveCategoryToFolder(label: "science", folderLabel: "gaming", sortOrder: 1)

    let defs = try await writer.fetchCategoryDefinitions()
    let science = defs.first { $0.label == "science" }
    #expect(science?.folderLabel == "gaming")
  }

  @Test
  func moveCategoryToRoot() async throws {
    let writer = try await makeWriter()
    try await seedFoldersAndCategories(writer)

    // Move apple (in technology) to root
    try await writer.moveCategoryToFolder(label: "apple", folderLabel: nil, sortOrder: 1)

    let defs = try await writer.fetchCategoryDefinitions()
    let apple = defs.first { $0.label == "apple" }
    #expect(apple?.folderLabel == nil)
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
    let defaults: [(label: String, displayName: String, description: String, sortOrder: Int, folderLabel: String?)] = [
      ("apple", "Apple", "Apple news", 0, "tech"),
      ("gaming", "Gaming", "Games", 0, nil),
      ("ps5", "PS5", "PS5 news", 0, "gaming"),
    ]
    try await writer.seedDefaultCategories(defaults)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.count == 3)

    let inFolder = defs.filter { $0.folderLabel != nil }
    #expect(inFolder.count == 2)
  }

  // MARK: - System category protection

  @Test
  func deleteSystemCategoryIsNoOp() async throws {
    let writer = try await makeWriter()
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    try await writer.deleteCategory(label: uncategorizedLabel)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  @Test
  func systemCategoryCannotBeMoved() async throws {
    let writer = try await makeWriter()
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    try await writer.moveCategoryToFolder(
      label: uncategorizedLabel, folderLabel: "tech", sortOrder: 0
    )

    let defs = try await writer.fetchCategoryDefinitions()
    let uncat = defs.first { $0.label == uncategorizedLabel }
    #expect(uncat?.folderLabel == nil)
  }
}
