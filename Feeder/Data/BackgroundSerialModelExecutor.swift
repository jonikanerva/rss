import Foundation
import SwiftData

// MARK: - Background serial model executor (off-main, STACK.md § 14)

/// A custom `SerialModelExecutor` that runs a SwiftData actor's jobs on a
/// dedicated BACKGROUND serial `DispatchQueue` — the off-main guarantee that
/// `DefaultSerialModelExecutor` does NOT provide. `ModelActor` /
/// `DefaultSerialModelExecutor` guarantee only SERIALISED access to the context
/// (thread-safety), not background execution: Instruments per-thread attribution
/// showed `DataReader`'s fetches running on the MAIN thread (18.85 s main vs
/// 0.99 s background — the felt-lag cause, issue #135), and `DataWriter` shared
/// the identical defect (issue #159). Binding an actor's executor to a
/// background queue moves every one of its methods off main.
///
/// SE-0392 custom actor executor. `DispatchSerialQueue` vends no public
/// `asUnownedSerialExecutor()` in the macOS 26 SDK, so this uses the canonical
/// wrap-a-`DispatchQueue` form: `enqueue` hands the job to the queue and runs it
/// via `UnownedJob.runSynchronously(on:)`, with `self` as the serial executor
/// (`UnownedSerialExecutor(ordinary:)`). `nonisolated` is REQUIRED — under
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a bare class would infer
/// `@MainActor` and run the actor back on main. `@unchecked Sendable` mirrors
/// `DefaultSerialModelExecutor`: the `ModelContext` is only ever touched on this
/// one serial queue, so each owning actor's own context contract (`DataReader`'s
/// read-only no-insert/save contract, `DataWriter`'s save-on-write contract, § 5)
/// holds per instance.
///
/// CRITICAL invariant: each actor constructs its OWN executor instance (its own
/// queue). Never share one instance between `DataReader` and `DataWriter` —
/// that would re-serialise reads behind writes on a single queue and reintroduce
/// the panel-2 starvation PR #160 fixed.
nonisolated final class BackgroundSerialModelExecutor: SerialModelExecutor, @unchecked Sendable {
  let modelContext: ModelContext
  private let queue: DispatchQueue

  init(modelContext: ModelContext, queueLabel: String) {
    self.modelContext = modelContext
    self.queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedJob(job)
    let executor = asUnownedSerialExecutor()
    queue.async {
      unownedJob.runSynchronously(on: executor)
    }
  }

  func asUnownedSerialExecutor() -> UnownedSerialExecutor {
    UnownedSerialExecutor(ordinary: self)
  }
}
