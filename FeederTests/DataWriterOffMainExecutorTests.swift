import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Regression detector for the off-main executor binding.
///
/// `DefaultSerialModelExecutor` runs an actor method's body on the awaiting
/// caller's thread, which is main for every MainActor call site, so a reverted
/// binding is a silent performance regression no functional assertion catches.
/// This suite is `@MainActor` to reproduce that call shape: every guarded
/// method opens with a not-on-main precondition, so a reverted binding traps
/// loudly instead of hanging quietly.
@MainActor
@Suite("DataWriter off-main executor")
struct DataWriterOffMainExecutorTests {
  @Test
  func guardedWriteRunsOffMainWhenAwaitedFromMainActor() async throws {
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = await DataWriter.makeDetached(
      modelContainer: container, defaultsFlagStore: InMemoryFlagStore())

    // `bootstrap()` is a guarded write (fetchCount + seed + save). The real
    // assertion is the precondition NOT trapping; the outcome check just
    // proves the write completed against the fresh store.
    let outcome = try await writer.bootstrap()
    #expect(outcome.action == .seeded)
  }
}
