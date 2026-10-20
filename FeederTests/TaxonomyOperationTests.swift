import Foundation
import Testing

@testable import Feeder

/// The taxonomy sheets and the category list act on a writer result only
/// through `TaxonomyOperation`. These tests pin that a failed write keeps the
/// sheet open, that a failed article count never reaches the delete, that a
/// move is announced only after success, and that one owner runs one write at
/// a time. The work closures are fakes, so no test touches a store.
@MainActor
@Suite("Taxonomy operation")
struct TaxonomyOperationTests {
  private struct WriteFailed: Error {}

  /// Records the calls that a fake write flow makes, in order.
  @MainActor
  private final class Recorder {
    var calls: [String] = []
  }

  private func waitForSettled(_ operation: TaxonomyOperation) async throws {
    try await waitUntil("operation settles") { await !operation.isRunning }
  }

  @Test
  func successRunsOnSuccessOnceAndReturnsToIdle() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()

    let accepted = operation.submit(
      failure: .save("category"),
      work: { recorder.calls.append("write") },
      onFailure: { recorder.calls.append("failure") },
      onSuccess: { recorder.calls.append("dismiss") }
    )
    try await waitForSettled(operation)

    #expect(accepted)
    #expect(recorder.calls == ["write", "dismiss"])
    #expect(operation.phase == .idle)
  }

  @Test
  func failureKeepsTheSheetOpenAndReportsTheFailure() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()

    operation.submit(
      failure: .save("category"),
      work: { throw WriteFailed() },
      onFailure: { recorder.calls.append("failure") },
      onSuccess: { recorder.calls.append("dismiss") }
    )
    try await waitForSettled(operation)

    #expect(recorder.calls == ["failure"])
    #expect(operation.failure == .save("category"))

    operation.clearFailure()
    #expect(operation.phase == .idle)
  }

  @Test
  func failureMapperReceivesTheThrownError() async throws {
    let operation = TaxonomyOperation()

    operation.submit(
      failure: { error in
        guard let error = error as? CategoryReassignError else { return .remove("category") }
        return TaxonomyEditFailure(title: "Couldn't remove category", message: error.localizedDescription)
      },
      work: { throw CategoryReassignError.targetMissing }
    )
    try await waitForSettled(operation)

    #expect(operation.failure?.message == CategoryReassignError.targetMissing.localizedDescription)
  }

  @Test
  func failedCountNeverCallsDelete() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()

    // The same chain as `CategoryEditSheet.beginDelete`: the delete is
    // submitted only from the success of the count.
    operation.submit(
      failure: .countArticles,
      work: { () async throws -> Int in throw WriteFailed() },
      onSuccess: { count in
        recorder.calls.append("count \(count)")
        operation.submit(
          failure: .remove("category"),
          work: { recorder.calls.append("delete") }
        )
      }
    )
    try await waitForSettled(operation)

    #expect(recorder.calls.isEmpty)
    #expect(operation.failure == .countArticles)
  }

  @Test
  func successfulCountCanSubmitTheDelete() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()

    operation.submit(
      failure: .countArticles,
      work: { 0 },
      onSuccess: { count in
        recorder.calls.append("count \(count)")
        let accepted = operation.submit(
          failure: .remove("category"),
          work: { recorder.calls.append("delete") },
          onSuccess: { recorder.calls.append("dismiss") }
        )
        recorder.calls.append(accepted ? "accepted" : "refused")
      }
    )
    try await waitUntil("delete dismisses") { await recorder.calls.last == "dismiss" }

    #expect(recorder.calls == ["count 0", "accepted", "delete", "dismiss"])
    #expect(operation.phase == .idle)
  }

  @Test
  func secondSubmitWhileRunningIsRefused() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()
    let gate = AsyncGate()

    let first = operation.submit(
      failure: .move("folder"),
      work: {
        recorder.calls.append("first")
        await gate.wait()
      },
      onSuccess: { recorder.calls.append("announce first") }
    )
    try await waitUntil("first write starts") { await recorder.calls == ["first"] }
    let second = operation.submit(
      failure: .move("folder"),
      work: { recorder.calls.append("second") },
      onSuccess: { recorder.calls.append("announce second") }
    )

    #expect(first)
    #expect(!second)
    #expect(operation.isRunning)

    gate.open()
    try await waitForSettled(operation)

    #expect(recorder.calls == ["first", "announce first"])
  }

  @Test
  func delayedFailureDoesNotAnnounceSuccess() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()
    let gate = AsyncGate()

    operation.submit(
      failure: .move("folder"),
      work: {
        await gate.wait()
        throw WriteFailed()
      },
      onSuccess: { recorder.calls.append("announce") }
    )
    #expect(operation.isRunning)

    gate.open()
    try await waitForSettled(operation)

    #expect(recorder.calls.isEmpty)
    #expect(operation.failure == .move("folder"))
  }

  @Test
  func cancelStopsTheWaitAndDropsTheLateResult() async throws {
    let operation = TaxonomyOperation()
    let recorder = Recorder()
    let gate = AsyncGate()

    operation.submit(
      failure: .save("folder"),
      work: {
        recorder.calls.append("write")
        await gate.wait()
        throw WriteFailed()
      },
      onFailure: { recorder.calls.append("failure") },
      onSuccess: { recorder.calls.append("dismiss") }
    )
    try await waitUntil("write starts") { await recorder.calls == ["write"] }

    operation.cancel()
    #expect(operation.phase == .idle)

    let next = operation.submit(
      failure: .save("folder"),
      work: {
        recorder.calls.append("next write")
        await gate.wait()
      },
      onSuccess: { recorder.calls.append("next dismiss") }
    )
    #expect(next)

    gate.open()
    try await waitUntil("next write settles") { await recorder.calls.last == "next dismiss" }

    // The cancelled write finished with a failure, but its result never reached
    // the phase or the callbacks of the next submission.
    #expect(recorder.calls == ["write", "next write", "next dismiss"])
    #expect(operation.phase == .idle)
  }
}
