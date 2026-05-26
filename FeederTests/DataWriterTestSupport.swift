import Foundation
import SwiftData
import Synchronization

@testable import Feeder

/// Shared test helpers for DataWriter integration tests.
enum DataWriterTestSupport {
  /// Build a writer wired to an in-memory container and an isolated
  /// in-memory flag store. The isolated store is what keeps the seeded-
  /// defaults sentinel deterministic across the test target — a flag set
  /// by an earlier test cannot bleed into a later one because each writer
  /// gets its own store instance.
  static func makeWriter() async throws -> DataWriter {
    let container = try makeInMemoryContainer()
    return DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
  }

  /// Creates an in-memory `ModelContainer` with the full app schema for tests
  /// that need direct `ModelContext` access (e.g. pure-function tests that
  /// insert SwiftData models without going through `DataWriter`).
  /// Routes through `FeederSchemaV2` + `FeederMigrationPlan` so tests
  /// exercise the same container shape production uses — if a future
  /// schema bump breaks the migration plan, these tests fail loudly
  /// instead of opening a bare schema that diverges from production.
  static func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: config
    )
  }
}

/// Per-test in-memory implementation of `SeededDefaultsFlagStore`.
/// `Mutex` keeps the underlying dictionary `Sendable`-safe so the store
/// can cross the `Task.detached` boundary `DataWriter.makeDetached` uses.
/// Bootstrap exercises a single key (`defaultsSeededUserDefaultsKey`), so
/// the storage is intentionally minimal.
final class InMemoryFlagStore: SeededDefaultsFlagStore {
  private let storage = Mutex<[String: Bool]>([:])

  func isSeeded(forKey key: String) -> Bool {
    storage.withLock { $0[key] ?? false }
  }

  func setSeeded(_ value: Bool, forKey key: String) {
    storage.withLock { $0[key] = value }
  }
}

/// Lightweight snapshot of an Entry for test assertions without crossing actor boundaries.
struct EntrySnapshot: Sendable {
  let feedbinEntryID: Int
  let isRead: Bool
  let isClassified: Bool
  let primaryCategory: String
  let primaryFolder: String
  let plainText: String
  let persistentModelID: PersistentIdentifier
}

extension DataWriter {
  func fetchEntrySnapshot(feedbinEntryID id: Int) throws -> EntrySnapshot? {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.feedbinEntryID == id }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return nil }
    return EntrySnapshot(
      feedbinEntryID: entry.feedbinEntryID,
      isRead: entry.isRead,
      isClassified: entry.isClassified,
      primaryCategory: entry.primaryCategory,
      primaryFolder: entry.primaryFolder,
      plainText: entry.plainText,
      persistentModelID: entry.persistentModelID
    )
  }
}
