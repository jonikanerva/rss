import Foundation

/// Single source of truth for whether the app boots headless: a self-contained,
/// seeded reading state that never reads credentials, never shows onboarding,
/// and never touches the network. An automated launch stays unattended, with no
/// Keychain consent prompt and no setup wizard.
///
/// There is no auto-detection. The trigger is exactly one explicit environment
/// variable, so no OS-settable value can flip the app into a
/// credential-skipping path in production.
///
/// Every headless hook must read `isEnabled` and nothing else. Reading the raw
/// environment variable anywhere would let the credential skip drift out of
/// lockstep with the in-memory-store gate, and the skip could then run while
/// the real on-disk store is open.
nonisolated enum HeadlessMode {
  /// True when the launch must boot headless. The flag denies real data and
  /// network access; it never grants extra access.
  static var isEnabled: Bool {
    isEnabled(in: ProcessInfo.processInfo.environment)
  }

  /// Pure core, parameterised by an environment snapshot so both cases are
  /// testable without mutating the process environment. This is the one place
  /// the `FEEDER_HEADLESS` key is read.
  static func isEnabled(in environment: [String: String]) -> Bool {
    environment["FEEDER_HEADLESS"] == "1"
  }
}
