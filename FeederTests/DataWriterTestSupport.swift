import Foundation
import SwiftData

@testable import Feeder

/// Shared test helpers for DataWriter integration tests.
enum DataWriterTestSupport {
  static func makeWriter() async throws -> DataWriter {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: Category.self, Entry.self, Feed.self,
      configurations: config
    )
    return DataWriter(modelContainer: container)
  }
}
