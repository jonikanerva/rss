import Foundation

@testable import Feeder

// MARK: - Fake classification provider

/// In-memory `ClassificationProvider` implementation for
/// `ClassificationEngineTests`. Lets the engine run end-to-end against a
/// fixed default response, an optional pre-configured error count, and an
/// optional per-call delay — without touching `UserDefaults`, the
/// Keychain, the on-device Foundation Model, or OpenAI.
///
/// Implemented as an `actor` so the fake stays trivially `Sendable` (the
/// protocol requires it) and so mutators called from tests don't race the
/// detached `ClassificationRunner` task that consumes `classify(...)`.
///
/// The surface is deliberately narrow — every member is exercised by at
/// least one `ClassificationEngineTests` case. Adding configuration knobs
/// "for future tests" would be dead scaffolding; grow the surface only
/// when a new test actually needs it.
actor FakeClassificationProvider: ClassificationProvider {
  // MARK: ClassificationProvider — synchronous metadata

  /// `nonisolated` to satisfy the protocol's synchronous requirement.
  /// Constant per instance — no actor state needs to be touched.
  nonisolated let name = "Fake"

  // MARK: State

  /// Fixed response every call returns. "tech" matches one of the
  /// categories `ClassificationEngineTests` seeds, so it survives the
  /// `validLabels` filter inside `DataWriter.applyClassification` and the
  /// confidence gate inside `ClassificationRunner.runOneBatch`.
  private static let defaultResponse = ProviderClassificationResult(
    category: "tech",
    storyKey: "fake-story",
    confidence: 1.0
  )

  /// Number of remaining `classify(...)` invocations that should `throw`
  /// before returning `defaultResponse`. Decremented on each thrown call.
  /// Lets `errorRecoveryContinuesWithNextBatch` model "fail the first N
  /// calls, succeed for the rest" without per-call state machinery.
  private var errorsRemaining = 0
  private var errorToThrow: Error?

  /// Delay inserted before each `classify(...)` returns. Used by tests
  /// that need to keep the runner suspended long enough for a
  /// `Task.cancel()` or a manual trigger to land between iterations.
  private var perCallDelay: Duration = .zero

  /// Count of `classify(...)` invocations. The single piece of observable
  /// state tests assert on.
  private(set) var callCount: Int = 0

  // MARK: - ClassificationProvider conformance

  /// Always available. No test exercises the unavailable branch — adding
  /// a toggle would be dead scaffolding.
  var isAvailable: Bool { true }

  /// Nil = "all languages". The runner's language-gate branch is exercised
  /// in pure-helper tests; integration tests don't need to flip it.
  var supportedLanguageCodes: Set<String>? { nil }

  func classify(
    title: String,
    body: String,
    url: String,
    instructions: String
  ) async throws -> ProviderClassificationResult {
    callCount += 1

    if perCallDelay > .zero {
      try? await Task.sleep(for: perCallDelay)
    }

    if errorsRemaining > 0, let error = errorToThrow {
      errorsRemaining -= 1
      throw error
    }

    return Self.defaultResponse
  }

  // MARK: - Test configuration setters

  /// Configure the fake to throw `error` on the next `count` calls before
  /// reverting to the default response. Used by
  /// `errorRecoveryContinuesWithNextBatch`.
  func configureErrors(_ error: Error, count: Int) {
    errorToThrow = error
    errorsRemaining = count
  }

  /// Insert `value` before each `classify(...)` returns. Used by the
  /// cancellation and slot-management tests to keep the runner's batch
  /// loop suspended long enough for a control-plane event to land.
  func configureDelay(_ value: Duration) {
    perCallDelay = value
  }
}

// MARK: - Test errors

/// Stable error type for `errorRecoveryContinuesWithNextBatch` so the test
/// doesn't have to reach into production error namespaces it isn't
/// otherwise exercising. Carries no payload — the runner's `catch` branch
/// only cares that *some* error was thrown.
struct FakeProviderError: Error {}
