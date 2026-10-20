import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "TaxonomyOperation")

/// Alert copy for a taxonomy write that did not complete. Category and folder
/// labels are public taxonomy strings, so a typed error text is safe to show
/// (`STACK.md § 8`).
struct TaxonomyEditFailure: Equatable {
  let title: String
  let message: String

  static func save(_ noun: String) -> TaxonomyEditFailure {
    TaxonomyEditFailure(title: "Couldn't save \(noun)", message: "Your changes are kept. Try again.")
  }

  static func create(_ noun: String) -> TaxonomyEditFailure {
    TaxonomyEditFailure(title: "Couldn't create \(noun)", message: "Your entries are kept. Try again.")
  }

  static func remove(_ noun: String) -> TaxonomyEditFailure {
    TaxonomyEditFailure(title: "Couldn't remove \(noun)", message: "The \(noun) was not removed. Try again.")
  }

  static let countArticles = TaxonomyEditFailure(
    title: "Couldn't remove category",
    message: "Feeder couldn't check the articles in this category, so the category was not removed. Try again."
  )

  static func move(_ noun: String) -> TaxonomyEditFailure {
    TaxonomyEditFailure(title: "Couldn't move \(noun)", message: "The previous order is kept. Try again.")
  }
}

/// Owns one taxonomy write at a time for a sheet or the category list. A
/// caller acts on the result only in `onSuccess`, so a failed write never
/// dismisses a sheet or announces a move. Cancellation stops the wait for the
/// result, not a write that the writer actor already runs.
@Observable
final class TaxonomyOperation {
  enum Phase: Equatable {
    case idle
    case running
    case failed(TaxonomyEditFailure)
  }

  private(set) var phase: Phase
  @ObservationIgnored
  private var task: Task<Void, Never>?
  /// Identifies the current submission, so a cancelled task that finishes late
  /// cannot change the phase of a later submission.
  @ObservationIgnored
  private var generation = 0

  init(phase: Phase = .idle) {
    self.phase = phase
  }

  var isRunning: Bool { phase == .running }

  var failure: TaxonomyEditFailure? {
    if case .failed(let failure) = phase { return failure }
    return nil
  }

  /// Start `work` unless a submission is running. Returns `false` when the
  /// submission is refused. The phase is `.idle` again before `onSuccess`
  /// runs, so `onSuccess` can submit the next step.
  @discardableResult
  func submit<Value>(
    failure: @escaping @MainActor (any Error) -> TaxonomyEditFailure,
    work: @escaping @MainActor () async throws -> Value,
    onFailure: @escaping @MainActor () -> Void = {},
    onSuccess: @escaping @MainActor (Value) -> Void = { _ in }
  ) -> Bool {
    guard !isRunning else { return false }
    generation += 1
    let submission = generation
    phase = .running
    task = Task {
      let result: Result<Value, any Error>
      do {
        result = .success(try await work())
      } catch {
        result = .failure(error)
      }
      guard submission == generation, !Task.isCancelled else { return }
      task = nil
      switch result {
      case .success(let value):
        phase = .idle
        onSuccess(value)
      case .failure(let error):
        logger.error("Taxonomy write failed: \(error.localizedDescription, privacy: .private)")
        phase = .failed(failure(error))
        onFailure()
      }
    }
    return true
  }

  @discardableResult
  func submit<Value>(
    failure: TaxonomyEditFailure,
    work: @escaping @MainActor () async throws -> Value,
    onFailure: @escaping @MainActor () -> Void = {},
    onSuccess: @escaping @MainActor (Value) -> Void = { _ in }
  ) -> Bool {
    submit(failure: { _ in failure }, work: work, onFailure: onFailure, onSuccess: onSuccess)
  }

  func clearFailure() {
    if case .failed = phase { phase = .idle }
  }

  /// Stop waiting for the running submission. Its `onSuccess` and `onFailure`
  /// never run.
  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    if phase == .running { phase = .idle }
  }
}

extension View {
  /// Show the failure of `operation` in a standard alert. Dismissing the alert
  /// clears the failure; the sheet and its edits stay as they were.
  func taxonomyFailureAlert(_ operation: TaxonomyOperation) -> some View {
    alert(
      operation.failure?.title ?? "",
      isPresented: Binding(
        get: { operation.failure != nil },
        set: { if !$0 { operation.clearFailure() } }
      ),
      actions: {
        Button("OK", role: .cancel) { operation.clearFailure() }
      },
      message: {
        Text(operation.failure?.message ?? "")
      }
    )
  }
}
