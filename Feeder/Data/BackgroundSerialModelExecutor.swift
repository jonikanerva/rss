import Foundation
import SwiftData

// MARK: - Background serial model executor

/// A custom `SerialModelExecutor` that runs a SwiftData actor's jobs on a
/// dedicated background serial `DispatchQueue`. `ModelActor` and
/// `DefaultSerialModelExecutor` guarantee serialised access to the context, not
/// background execution, so binding the executor here is what moves every one
/// of the owning actor's methods off main (`STACK.md § 14`).
///
/// `nonisolated` is required: under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// a bare class infers `@MainActor` and runs the actor back on main.
/// `@unchecked Sendable` holds because the `ModelContext` is touched only on
/// this one serial queue, so each owning actor's own context contract holds per
/// instance.
///
/// Each actor must construct its own executor instance, and therefore its own
/// queue. Sharing one instance between `DataReader` and `DataWriter` would
/// re-serialise reads behind writes.
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
