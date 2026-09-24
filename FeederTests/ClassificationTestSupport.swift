import Foundation

@testable import Feeder

// MARK: - Fake classification provider

/// In-memory `ClassificationProvider` for the engine tests. The engine runs end
/// to end against a fixed response, an optional error count, and an optional
/// per-call delay, without touching `UserDefaults`, the Keychain, or a real
/// backend.
///
/// An `actor`, so the fake stays `Sendable` as the protocol requires and a
/// mutator called from a test cannot race the detached runner.
///
/// Keep the surface narrow: every member is exercised by at least one test, and
/// a knob added for a future test is dead scaffolding.
actor FakeClassificationProvider {
  // MARK: ClassificationProvider — synchronous metadata

  /// `nonisolated`, to satisfy the protocol's synchronous requirement. Constant
  /// per instance, so it touches no actor state.
  nonisolated let name = "Fake"

  // MARK: State

  /// The fixed response every call returns. Its label matches a category the
  /// tests seed, so it survives both the valid-label filter and the confidence
  /// gate.
  ///
  /// `nonisolated`: a static on an actor is not instance-isolated, so under
  /// default MainActor isolation it would be unreadable from the actor-isolated
  /// witness. An immutable `Sendable` value needs no isolation.
  private nonisolated static let defaultResponse = ProviderClassificationResult.generative(
    category: "tech",
    confidence: 1.0
  )

  /// How many further calls must throw before the default response returns.
  /// Decremented on each thrown call, so a test models "fail the first calls,
  /// succeed for the rest" with no per-call state machinery.
  private var errorsRemaining = 0
  private var errorToThrow: Error?

  /// How many leading calls must succeed before the configured error starts
  /// throwing, so an abort-path test asserts the persisted successes against the
  /// untouched remainder.
  private var successesBeforeError = 0

  /// Delay before each call returns, which keeps the runner suspended long
  /// enough for a cancellation or a manual trigger to land between iterations.
  private var perCallDelay: Duration = .zero

  /// Call count: the one piece of observable state the tests assert on.
  private(set) var callCount: Int = 0

  // MARK: - ClassificationProvider conformance

  /// The availability the runner's guard sees. One test flips it, to prove the
  /// early return emits an owning provider-unavailable outcome.
  private var available = true
  private var validationError: VercelClassificationError?

  var isAvailable: Bool { available }

  /// `nil` means every language. The pure-helper tests exercise the runner's
  /// language gate, so an integration test never flips this.
  var supportedLanguageCodes: Set<String>? { nil }

  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    callCount += 1

    if perCallDelay > .zero {
      try? await Task.sleep(for: perCallDelay)
    }

    if errorsRemaining > 0, let error = errorToThrow, callCount > successesBeforeError {
      errorsRemaining -= 1
      throw error
    }

    return Self.defaultResponse
  }

  func validate(categories: [CategoryDefinition]) async throws {
    if let validationError { throw validationError }
  }

  func configureValidation(_ error: VercelClassificationError?) { validationError = error }

  // MARK: - Test configuration setters

  /// Throw `error` on the next `count` calls, then revert to the default
  /// response. `afterSuccesses` shifts that failure window past a number of
  /// leading successful calls.
  func configureErrors(_ error: Error, count: Int, afterSuccesses: Int = 0) {
    errorToThrow = error
    errorsRemaining = count
    successesBeforeError = afterSuccesses
  }

  /// Insert `value` before each call returns, which keeps the runner's batch
  /// loop suspended long enough for a control event to land.
  func configureDelay(_ value: Duration) {
    perCallDelay = value
  }

  /// Flip the availability the runner's guard reads.
  func configureAvailability(_ value: Bool) {
    available = value
  }
}

/// The conformance sits in an extension on purpose: on the primary declaration
/// the protocol's `nonisolated` would be inferred onto the actor itself, which
/// the compiler rejects. The actor-isolated members satisfy the protocol's
/// async requirements as usual.
extension FakeClassificationProvider: ClassificationProvider {}

// MARK: - Fake cloud transport

actor ClassificationTransportRecorder {
  private(set) var requests: [URLRequest] = []
  private let script: [Result<ClassificationHTTPResponse, any Error>]

  init(data: Data, status: Int = 200, retryAfter: String? = nil) {
    self.init(script: [.success(.status(status, retryAfter: retryAfter, data: data))])
  }

  /// Answers each request with the next script entry. The last entry repeats.
  init(script: [Result<ClassificationHTTPResponse, URLError>]) {
    precondition(!script.isEmpty, "A transport script needs at least one entry")
    self.script = script.map { $0.mapError { $0 } }
  }

  /// Throws `failure` for every request.
  init(failure: any Error) {
    script = [.failure(failure)]
  }

  func send(_ request: URLRequest) throws -> ClassificationHTTPResponse {
    requests.append(request)
    return try script[min(requests.count, script.count) - 1].get()
  }
}

extension ClassificationHTTPResponse {
  static func status(_ code: Int, retryAfter: String? = nil, data: Data = Data()) -> ClassificationHTTPResponse {
    ClassificationHTTPResponse(data: data, statusCode: code, retryAfter: retryAfter)
  }
}

// MARK: - OpenAI error bodies

enum OpenAIErrorBodies {
  static let billing = [
    #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#,
    #"{"error":{"message":"Your organization has no prepaid credits remaining.","type":"insufficient_quota","param":null,"code":"credit_balance_exhausted"}}"#,
    #"{"error":{"code":"insufficient_quota"}}"#,
    #"{"error":{"code":"credit_balance_exhausted"}}"#,
    #"{"error":{"code":"organization_spend_limit_exceeded"}}"#,
    #"{"error":{"code":"project_spend_limit_exceeded"}}"#,
    #"{"error":{"code":"organization_usage_limit_exceeded"}}"#,
    #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":null}}"#,
  ]

  static let rateLimit = [
    #"{"error":{"message":"Rate limit reached for requests.","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#,
    #"{"error":{"message":"Your request rate increased too quickly.","type":"rate_limit_error","param":null,"code":"slow_down"}}"#,
    "",
    "not json at all",
    #"{"error":{"code":429}}"#,
  ]
}

// MARK: - Snapshot recorder

/// Records the snapshot timeline the runner reports. Driving the runner
/// directly and recording every snapshot lets a test assert on the full
/// sequence, including the drain-end snapshot the engine collapses into its
/// terminal reset. An `actor`, so the reporter closure appends without a race.
actor SnapshotRecorder {
  private(set) var snapshots: [ProgressSnapshot] = []

  func record(_ snapshot: ProgressSnapshot) {
    snapshots.append(snapshot)
  }
}

// MARK: - Test errors

/// Stable error type for the error-recovery test, so it reaches into no
/// production error namespace. It carries no payload: the runner's catch branch
/// only cares that something was thrown.
struct FakeProviderError: Error {}

/// Test error with a configurable disposition, which drives both the abort
/// branch and the per-entry-fallback branch of the runner's failure handling.
/// `nonisolated`, because the synchronous witness must be callable off the main
/// actor, where the runner catches it.
nonisolated struct FakeClassificationFailure: ClassificationFailure {
  let batchAbort: ClassificationAbortReason?
}
