import Foundation
import SwiftData

@testable import Feeder

/// Shared test helpers for DataWriter integration tests.
enum DataWriterTestSupport {
  static func makeWriter() async throws -> DataWriter {
    let container = try makeInMemoryContainer()
    return DataWriter(modelContainer: container)
  }

  /// Creates an in-memory `ModelContainer` with the full app schema for tests
  /// that need direct `ModelContext` access (e.g. pure-function tests that
  /// insert SwiftData models without going through `DataWriter`).
  static func makeInMemoryContainer() throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: Category.self, Entry.self, Feed.self, Folder.self,
      configurations: config
    )
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
