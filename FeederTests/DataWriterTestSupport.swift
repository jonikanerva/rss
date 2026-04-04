import Foundation
import SwiftData

@testable import Feeder

/// Shared test helpers for DataWriter integration tests.
enum DataWriterTestSupport {
  static func makeWriter() async throws -> DataWriter {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: Category.self, Entry.self, Feed.self, Folder.self,
      configurations: config
    )
    return DataWriter(modelContainer: container)
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
      plainText: entry.plainText
    )
  }
}
