import Foundation
import Synchronization

@testable import Feeder

// MARK: - Async gate

/// One-shot latch: every `wait()` returns after `open()`, and any number of
/// callers can wait at once. `wait()` ignores cancellation: a cancelled waiter
/// still waits for `open()`.
final class AsyncGate: Sendable {
  private let continuation: AsyncStream<Void>.Continuation
  private let opened: Task<Void, Never>

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    self.continuation = continuation
    opened = Task {
      for await _ in stream {}
    }
  }

  func open() { continuation.finish() }

  func wait() async { await opened.value }
}

// MARK: - Recording credential store

/// Records each store call in order and answers from its configuration, with
/// no Keychain access.
actor RecordingFeedbinCredentialStore {
  enum Call: Equatable {
    case load
    case add(FeedbinCredentials)
    case remove
    case loadLegacy
    case removeLegacy
  }

  private(set) var calls: [Call] = []
  private var loadResult: Result<FeedbinCredentials?, KeychainError>
  private let legacyResult: Result<FeedbinCredentials?, KeychainError>
  private let loadGate: AsyncGate?
  private var addFailure: KeychainError?
  private var removeFailure: KeychainError?

  /// With a gate, each `load()` records its call and then waits for the gate.
  init(
    loadResult: Result<FeedbinCredentials?, KeychainError> = .success(nil),
    legacyResult: Result<FeedbinCredentials?, KeychainError> = .success(nil),
    loadGate: AsyncGate? = nil
  ) {
    self.loadResult = loadResult
    self.legacyResult = legacyResult
    self.loadGate = loadGate
  }

  func setLoadResult(_ result: Result<FeedbinCredentials?, KeychainError>) { loadResult = result }
  func configureAddFailure(_ failure: KeychainError?) { addFailure = failure }
  func configureRemoveFailure(_ failure: KeychainError?) { removeFailure = failure }

  func load() async throws(KeychainError) -> FeedbinCredentials? {
    calls.append(.load)
    if let loadGate { await loadGate.wait() }
    return try loadResult.get()
  }

  func add(_ credentials: FeedbinCredentials) throws(KeychainError) {
    calls.append(.add(credentials))
    if let addFailure { throw addFailure }
  }

  func remove() throws(KeychainError) {
    calls.append(.remove)
    if let removeFailure { throw removeFailure }
  }

  func loadLegacy() throws(KeychainError) -> FeedbinCredentials? {
    calls.append(.loadLegacy)
    return try legacyResult.get()
  }

  func removeLegacy() {
    calls.append(.removeLegacy)
  }
}

extension RecordingFeedbinCredentialStore: FeedbinCredentialStore {}

// MARK: - Recording client factory

/// Stands in for the engine's live client factory: records the credentials of
/// each build and returns the fake that `clientFor` picks.
@MainActor
final class RecordingClientFactory {
  private(set) var builtFor: [FeedbinCredentials] = []
  private let clientFor: (FeedbinCredentials) -> FakeFeedbinClient

  init(_ clientFor: @escaping (FeedbinCredentials) -> FakeFeedbinClient = { _ in FakeFeedbinClient() }) {
    self.clientFor = clientFor
  }

  func make(_ credentials: FeedbinCredentials) -> any FeedbinClientProtocol {
    builtFor.append(credentials)
    return clientFor(credentials)
  }
}

// MARK: - Start marker

/// Lets a test wait until the tasks it started have run to their first
/// suspension: each task marks, then calls the engine in the same main-actor
/// job, so a mark means that call is already parked.
@MainActor
final class StartMarker {
  private(set) var marks = 0

  func mark() { marks += 1 }
}

// MARK: - Change flag

/// Set from an observation `onChange` handler, which may run on any thread.
final class ChangeFlag: Sendable {
  private let value = Atomic<Bool>(false)

  var isSet: Bool { value.load(ordering: .relaxed) }

  func set() { value.store(true, ordering: .relaxed) }
}
