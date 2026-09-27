import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Keep the suite `@MainActor`: the SwiftUI read sites await `DataReader` from
/// the main actor, and the test must use the same call shape.
@MainActor
@Suite("DataReader off-main executor")
struct DataReaderOffMainExecutorTests {
  @Test
  func guardedReadsRunOffMainWhenAwaitedFromMainActor() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let reader = await DataReader.makeDetached(modelContainer: container)

    // Keep the probe before the reads: a read on the main thread traps on its
    // precondition and crashes the test host.
    let runsOnMainThread = await reader.runsOnMainThread()
    try #require(!runsOnMainThread)

    let result = try await reader.fetchEntrySections(
      category: "any", folder: nil, showRead: false, cutoffDate: .distantPast,
      window: .firstPage(limit: 10))
    let snapshot = try await reader.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    let favicons = try await reader.fetchFaviconData(feedbinFeedIDs: [1])
    #expect(result == .empty)
    #expect(snapshot == .empty)
    #expect(favicons.isEmpty)
  }
}

extension DataReader {
  /// Keep this method synchronous: `Thread.isMainThread` is unavailable in an
  /// async function.
  fileprivate func runsOnMainThread() -> Bool {
    Thread.isMainThread
  }
}
