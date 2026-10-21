import Foundation
import SQLite3
import SwiftData

@testable import Feeder

/// A temporary on-disk store whose writes can be made to fail. A trigger on a
/// store table forces the save failure. The trigger body raises a plain SQLite
/// error: Core Data reads a `RAISE` constraint error on an update as an
/// optimistic-locking conflict and retries the save without end.
struct FailingWriteStore {
  private static let failingTrigger = "feeder_test_failing_write"

  private let folder: URL
  private var storeURL: URL { folder.appending(path: "Feeder.store") }

  init() throws {
    folder = FileManager.default.temporaryDirectory.appending(path: "FeederSaveFailure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
  }

  func removeFolder() {
    try? FileManager.default.removeItem(at: folder)
  }

  /// Opens the store with the newest schema in the migration plan.
  func makeWriterAndReader() async throws -> (DataWriter, DataReader) {
    guard let newest = FeederMigrationPlan.schemas.last else { throw StoreSQLError(message: "no schema") }
    let schema = Schema(versionedSchema: newest)
    let config = ModelConfiguration(schema: schema, url: storeURL)
    let container = try ModelContainer(
      for: schema, migrationPlan: FeederMigrationPlan.self, configurations: config)
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
    let reader = await DataReader.makeDetached(modelContainer: container)
    return (writer, reader)
  }

  /// `published` defaults to the fixture date, which is older than the
  /// article cutoff that a `SyncEngine` computes from the clock.
  func seedUnreadEntries(_ writer: DataWriter, ids: [Int], published: Date? = nil) async throws {
    try await writer.syncFeeds([try FeedbinFixtures.subscription(id: 1, feedId: 100)])
    let entries = try ids.map { id in
      if let published {
        try FeedbinFixtures.entry(id: id, published: formatDateForFeedbin(published))
      } else {
        try FeedbinFixtures.entry(id: id)
      }
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(ids))
  }

  /// Every `event` (`INSERT` or `UPDATE`) on `table` fails until
  /// `dropFailingTrigger` runs. `table` is the Core Data table name.
  func installFailingTrigger(_ event: String, on table: String) throws {
    try executeSQL(
      """
      CREATE TRIGGER \(Self.failingTrigger) BEFORE \(event) ON \(table)
      BEGIN SELECT json('{'); END;
      """)
  }

  func dropFailingTrigger() throws {
    try executeSQL("DROP TRIGGER \(Self.failingTrigger);")
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
}

struct StoreSQLError: Error {
  let message: String
}
