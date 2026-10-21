import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Feeder

// MARK: - DataWriter Save Failure Tests

/// A failed write must leave nothing pending in the writer's context, so a
/// later, unrelated save cannot commit the failed mutation. A trigger on a
/// temporary on-disk store forces the save failure. The trigger body raises a
/// plain SQLite error: Core Data reads a `RAISE` constraint error on an update
/// as an optimistic-locking conflict and retries the save without end.
@Suite(.serialized)
struct DataWriterSaveFailureTests {
  private static let failingTrigger = "feeder_test_failing_write"

  private let folder: URL
  private var storeURL: URL { folder.appending(path: "Feeder.store") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(path: "FeederSaveFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  }

  private func removeTemporaryFolder() {
    try? FileManager.default.removeItem(at: folder)
  }

  /// Opens the store with the newest schema in the migration plan.
  private func makeWriterAndReader() async throws -> (DataWriter, DataReader) {
    let schema = Schema(versionedSchema: try #require(FeederMigrationPlan.schemas.last))
    let config = ModelConfiguration(schema: schema, url: storeURL)
    let container = try ModelContainer(
      for: schema, migrationPlan: FeederMigrationPlan.self, configurations: config)
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
    let reader = await DataReader.makeDetached(modelContainer: container)
    return (writer, reader)
  }

  private func seedEntries(_ writer: DataWriter, ids: [Int]) async throws {
    try await writer.syncFeeds([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    let entries = try ids.map { try FeedbinFixtures.entry(id: $0) }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
  }

  /// Runs `sql` on a second SQLite connection to the store file.
  private func executeSQL(_ sql: String) throws {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    guard sqlite3_open(storeURL.path, &database) == SQLITE_OK,
      sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    else {
      throw StoreSQLError(message: String(cString: sqlite3_errmsg(database)))
    }
  }

  /// Every `event` (`INSERT` or `UPDATE`) on `table` fails until
  /// `dropFailingTrigger` runs. `table` is the Core Data table name.
  private func installFailingTrigger(_ event: String, on table: String) throws {
    try executeSQL(
      """
      CREATE TRIGGER \(Self.failingTrigger) BEFORE \(event) ON \(table)
      BEGIN SELECT json('{'); END;
      """)
  }

  private func dropFailingTrigger() throws {
    try executeSQL("DROP TRIGGER \(Self.failingTrigger);")
  }

  // MARK: - Save failure

  @Test
  func failedInsertDoesNotLeakIntoTheNextSave() async throws {
    defer { removeTemporaryFolder() }
    let (writer, reader) = try await makeWriterAndReader()
    try await seedEntries(writer, ids: [1001, 1002])

    try installFailingTrigger("INSERT", on: "ZFOLDER")
    await #expect(throws: (any Error).self) {
      try await writer.addFolder(label: "failed", displayName: "Failed", sortOrder: 99)
    }
    #expect(await writer.testHasPendingChanges == false)
    try dropFailingTrigger()

    try await writer.markEntriesRead(feedbinEntryIDs: [1002])

    #expect(await writer.testHasPendingChanges == false)
    #expect(try await writer.fetchFolderSortOrder(label: "failed") == nil)
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.unreadFeedbinEntryIDs == [1001])
  }

  @Test
  func failedUpdateDoesNotLeakIntoTheNextSave() async throws {
    defer { removeTemporaryFolder() }
    let (writer, reader) = try await makeWriterAndReader()
    try await seedEntries(writer, ids: [1001, 1002])

    try installFailingTrigger("UPDATE", on: "ZENTRY")
    await #expect(throws: (any Error).self) {
      try await writer.markEntriesRead(feedbinEntryIDs: [1001])
    }
    #expect(await writer.testHasPendingChanges == false)
    try dropFailingTrigger()

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
    defer { removeTemporaryFolder() }
    let (writer, _) = try await makeWriterAndReader()
    try await writer.addCategory(label: "apple", displayName: "Apple", description: "Apple Inc.", sortOrder: 0)
    try await seedEntries(writer, ids: [1001])

    try installFailingTrigger("UPDATE", on: "ZCATEGORY")
    await #expect(throws: (any Error).self) {
      try await writer.updateCategoryFields(label: "apple", displayName: "Failed", description: "Failed")
    }
    #expect(await writer.testHasPendingChanges == false)
    try dropFailingTrigger()

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
    defer { removeTemporaryFolder() }
    let (writer, reader) = try await makeWriterAndReader()
    try await writer.addFolder(label: "technology", displayName: "Technology", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple", description: "Apple Inc.", sortOrder: 0, folderLabel: "technology")
    try await writer.addCategory(
      label: "ai", displayName: "AI", description: "AI news", sortOrder: 1, folderLabel: "technology")
    try await seedEntries(writer, ids: [1001])
    try await writer.applyClassification(
      entryID: 1001, result: ClassificationResult(entryID: 1001, categoryLabel: "apple"))

    try installFailingTrigger("UPDATE", on: "ZENTRY")
    await #expect(throws: (any Error).self) {
      _ = try await writer.removeCategoryAndReassignArticles("apple", to: "ai")
    }
    #expect(await writer.testHasPendingChanges == false)
    try dropFailingTrigger()

    try await writer.markEntriesRead(feedbinEntryIDs: [1001])

    #expect(try await writer.fetchCategoryDefinitions().contains { $0.label == "apple" })
    let entry = try await writer.fetchEntrySnapshot(feedbinEntryID: 1001)
    #expect(entry?.primaryCategory == "apple")
    #expect(entry?.isRead == true)
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.unreadFeedbinEntryIDs.isEmpty)
  }
}

private struct StoreSQLError: Error {
  let message: String
}
