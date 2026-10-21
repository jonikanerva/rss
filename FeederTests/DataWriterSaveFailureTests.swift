import Foundation
import SwiftData
import Testing

@testable import Feeder

// MARK: - DataWriter Save Failure Tests

/// A failed write must leave nothing pending in the writer's context, so a
/// later, unrelated save cannot commit the failed mutation.
@Suite(.serialized)
struct DataWriterSaveFailureTests {
  private let store: FailingWriteStore

  init() throws {
    store = try FailingWriteStore()
  }

  // MARK: - Save failure

  @Test
  func failedInsertDoesNotLeakIntoTheNextSave() async throws {
    defer { store.removeFolder() }
    let (writer, reader) = try await store.makeWriterAndReader()
    try await store.seedUnreadEntries(writer, ids: [1001, 1002])

    try store.installFailingTrigger("INSERT", on: "ZFOLDER")
    await #expect(throws: (any Error).self) {
      try await writer.addFolder(label: "failed", displayName: "Failed", sortOrder: 99)
    }
    #expect(await writer.testHasPendingChanges == false)
    try store.dropFailingTrigger()

    try await writer.markEntriesRead(feedbinEntryIDs: [1002])

    #expect(await writer.testHasPendingChanges == false)
    #expect(try await writer.fetchFolderSortOrder(label: "failed") == nil)
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.unreadFeedbinEntryIDs == [1001])
  }

  @Test
  func failedUpdateDoesNotLeakIntoTheNextSave() async throws {
    defer { store.removeFolder() }
    let (writer, reader) = try await store.makeWriterAndReader()
    try await store.seedUnreadEntries(writer, ids: [1001, 1002])

    try store.installFailingTrigger("UPDATE", on: "ZENTRY")
    await #expect(throws: (any Error).self) {
      try await writer.markEntriesRead(feedbinEntryIDs: [1001])
    }
    #expect(await writer.testHasPendingChanges == false)
    try store.dropFailingTrigger()

    try await writer.addFolder(label: "later", displayName: "Later", sortOrder: 1)

    #expect(await writer.testHasPendingChanges == false)
    #expect(try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)?.isRead == false)
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.unreadFeedbinEntryIDs == [1001, 1002])
  }

  /// A failed update of a model that is not an `Entry` does not reach a later
  /// save either. A separate context reads what the store holds.
  @Test
  func failedCategoryUpdateDoesNotLeakIntoTheNextSave() async throws {
    defer { store.removeFolder() }
    let (writer, _) = try await store.makeWriterAndReader()
    try await writer.addCategory(label: "apple", displayName: "Apple", description: "Apple Inc.", sortOrder: 0)
    try await store.seedUnreadEntries(writer, ids: [1001])

    try store.installFailingTrigger("UPDATE", on: "ZCATEGORY")
    await #expect(throws: (any Error).self) {
      try await writer.updateCategoryFields(label: "apple", displayName: "Failed", description: "Failed")
    }
    #expect(await writer.testHasPendingChanges == false)
    try store.dropFailingTrigger()

    try await writer.markEntriesRead(feedbinEntryIDs: [1001])

    let storeContext = ModelContext(writer.modelContainer)
    let stored = try storeContext.fetch(FetchDescriptor<Feeder.Category>()).first
    #expect(stored?.displayName == "Apple")
    #expect(stored?.categoryDescription == "Apple Inc.")
  }

  /// The reassignment updates entries and deletes the source category in one
  /// save, so a failed entry update keeps the source category too.
  @Test
  func failedReassignmentKeepsCategoryAndEntries() async throws {
    defer { store.removeFolder() }
    let (writer, reader) = try await store.makeWriterAndReader()
    try await writer.addFolder(label: "technology", displayName: "Technology", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple Inc.", sortOrder: 0, folderLabel: "technology")
    try await writer.addCategory(
      label: "ai", displayName: "AI", description: "AI news", sortOrder: 1, folderLabel: "technology")
    try await store.seedUnreadEntries(writer, ids: [1001])
    try await writer.applyClassification(
      entryID: 1001, result: ClassificationResult(entryID: 1001, categoryLabel: "apple"))

    try store.installFailingTrigger("UPDATE", on: "ZENTRY")
    await #expect(throws: (any Error).self) {
      _ = try await writer.removeCategoryAndReassignArticles("apple", to: "ai")
    }
    #expect(await writer.testHasPendingChanges == false)
    try store.dropFailingTrigger()

    try await writer.markEntriesRead(feedbinEntryIDs: [1001])

    #expect(try await writer.fetchCategoryDefinitions().contains { $0.label == "apple" })
    let entry = try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)
    #expect(entry?.primaryCategory == "apple")
    #expect(entry?.isRead == true)
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.unreadFeedbinEntryIDs.isEmpty)
  }
}
