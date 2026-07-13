import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Regression detector for the off-main executor binding (issues #135 / #159).
///
/// `DefaultSerialModelExecutor` runs an actor method's body on the AWAITING
/// caller's thread — main, for every MainActor call site — so a reverted
/// executor binding is a silent perf regression that no functional assertion
/// catches. This suite is explicitly `@MainActor` to reproduce the production
/// call shape: every guarded `DataWriter` method opens with
/// `dispatchPrecondition(condition: .notOnQueue(.main))`, so if the
/// `BackgroundSerialModelExecutor` binding ever reverts, the write runs on
/// main and the precondition traps — a loud crash instead of a quiet hang.
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
