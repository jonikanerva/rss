import Foundation

/// Single source of truth for whether the app should boot in **headless mode**:
/// a self-contained, seeded reading state that never reads credentials, never
/// shows onboarding, and never touches the network. Explicit opt-in launches use
/// it so they are fully unattended: no macOS Keychain consent prompt (which
/// blocks the run until a human clicks Allow) and no setup wizard (#141).
///
/// `make test` sets `FEEDER_HEADLESS=1` on the XCTest host (via the
/// `TEST_RUNNER_` prefix) so the unit-test run is unattended; a measurement or
/// perf run can set it the same way. There is NO auto-detection — the trigger is
/// exactly one explicit environment variable, so no OS-settable value (like
/// `XCTestConfigurationFilePath`) can flip the app into a credential-skipping
/// path in production.
///
/// Every headless hook MUST read `isEnabled` and nothing else: the in-memory-
/// store gate in `FeederApp.init`, the credential-skip branch in
/// `ContentView.checkCredentials`, and the seam-2 fake classification provider.
/// Reading a raw environment variable in any of them instead would let the
/// credential-skip drift out of lockstep with the store gate — the skip could
/// then run while the real on-disk store is open. One reader guarantees the two
/// gates fire together.
nonisolated enum HeadlessMode {
  /// True when the launch must boot headless. Runtime-only, gated on the single
  /// explicit `FEEDER_HEADLESS` flag — like `FEEDER_PERF_MODE`. A runtime flag's
  /// worst case is benign: it denies real data / network, never grants extra
  /// access.
  static var isEnabled: Bool {
    isEnabled(in: ProcessInfo.processInfo.environment)
  }

  /// Pure core, parameterised by an environment snapshot so both the enabled and
  /// disabled cases are unit-testable without mutating the process environment.
  /// This is the ONE place the `FEEDER_HEADLESS` key is read.
  static func isEnabled(in environment: [String: String]) -> Bool {
    environment["FEEDER_HEADLESS"] == "1"
  }
}
