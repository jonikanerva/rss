import Foundation

@testable import Feeder

// MARK: - Fake classification provider

/// In-memory `ClassificationProvider` implementation for
/// `ClassificationEngineTests`. Lets the engine run end-to-end against a
/// configurable response, optional thrown error, and an optional per-call
/// delay — without touching `UserDefaults`, the Keychain, the on-device
/// Foundation Model, or OpenAI.
///
/// Implemented as an `actor` so the fake stays trivially `Sendable` (the
/// protocol requires it) and so mutators called from tests don't race the
/// detached `ClassificationRunner` task that consumes `classify(...)`.
///
/// The configuration model mirrors `FakeFeedbinClient` from
/// `SyncEngineTestSupport.swift`: a configurable response, an optional
/// error, and a call log — kept narrow to exactly what
/// `ClassificationEngineTests` needs and nothing more.
actor FakeClassificationProvider: ClassificationProvider {
  // MARK: ClassificationProvider — synchronous metadata

  /// `nonisolated` to satisfy the protocol's synchronous requirement.
  /// Constant per instance — no actor state needs to be touched.
  nonisolated let name = "Fake"

  // MARK: Configurable behaviour

  /// Response returned by `classify(...)` on every call (until an error is
  /// configured). Defaults to a category of "tech" with full confidence so
  /// happy-path tests can use the fake with zero configuration.
  private var response = ProviderClassificationResult(
    category: "tech",
    storyKey: "fake-story",
    confidence: 1.0
  )

  /// Number of remaining `classify(...)` invocations that should `throw`
  /// before returning the configured response. Decremented each time an
  /// error is thrown. Lets `errorRecoveryContinuesWithNextBatch` model
  /// "fail the first call, succeed for the rest" without per-call state
  /// machinery.
  private var errorsRemaining = 0
  private var errorToThrow: Error?

  /// Delay inserted before each `classify(...)` returns. Used by the
  /// cancellation test to keep the loop suspended long enough for a
  /// `Task.cancel()` to land between iterations.
  private var perCallDelay: Duration = .zero

  /// Languages the engine will treat as supported. `nil` means "all
  /// languages" — the production contract.
  private var supportedLanguages: Set<String>? = nil

  /// Toggle for `isAvailable`. Defaults to true so happy-path tests don't
  /// need to configure it.
  private var available = true

  // MARK: Call log

  private(set) var classifyCalls: [ClassifyCall] = []

  /// Captured arguments of one `classify(...)` invocation. Tests assert on
  /// `entryID`-derived fields (via the title/url Feedbin fixtures use) but
  /// the full payload is recorded for future assertions.
  struct ClassifyCall: Sendable {
    let title: String
    let body: String
    let url: String
    let instructions: String
  }

  var callCount: Int { classifyCalls.count }

  // MARK: - ClassificationProvider conformance

  var isAvailable: Bool { available }

  var supportedLanguageCodes: Set<String>? { supportedLanguages }

  func classify(
    title: String,
    body: String,
    url: String,
    instructions: String
  ) async throws -> ProviderClassificationResult {
    classifyCalls.append(
      ClassifyCall(title: title, body: body, url: url, instructions: instructions)
    )

    if perCallDelay > .zero {
      try? await Task.sleep(for: perCallDelay)
    }

    if errorsRemaining > 0, let error = errorToThrow {
      errorsRemaining -= 1
      throw error
    }

    return response
  }

  // MARK: - Test configuration setters

  func configureResponse(_ value: ProviderClassificationResult) {
    response = value
  }

  /// Configure the fake to throw `error` on the next `count` calls before
  /// reverting to the configured response. Used by
  /// `errorRecoveryContinuesWithNextBatch`.
  func configureErrors(_ error: Error, count: Int) {
    errorToThrow = error
    errorsRemaining = count
  }

  func configureDelay(_ value: Duration) {
    perCallDelay = value
  }

  func configureSupportedLanguages(_ value: Set<String>?) {
    supportedLanguages = value
  }

  func configureAvailable(_ value: Bool) {
    available = value
  }
}

// MARK: - Test errors

/// Stable error type for `errorRecoveryContinuesWithNextBatch` so the test
/// doesn't have to reach into production error namespaces it isn't
/// otherwise exercising.
struct FakeProviderError: Error, Equatable {
  let message: String
}
