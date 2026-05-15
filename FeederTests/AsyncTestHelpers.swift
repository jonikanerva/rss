import Foundation
import Testing

// MARK: - Async polling helper

/// Poll `condition` until it returns `true` or `timeout` elapses, sleeping
/// 5 ms between checks. Records a test issue on timeout (without throwing)
/// so the calling test can decide whether to also assert on the
/// post-condition state — matching the behaviour of the
/// `SyncEngineTests` / `ClassificationEngineTests` race-guards that this
/// helper consolidates.
///
/// `description` is interpolated into the timeout `Issue.record` message
/// so the failure surface stays specific even though the helper itself
/// is generic. The closure is `@Sendable` so callers can read state from
/// actors (`await client.callCount`) without crossing isolation by hand.
///
/// Lives in the test target only.
func waitUntil(
  _ description: String,
  timeout: Duration = .seconds(2),
  condition: @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while await condition() == false {
    if ContinuousClock.now >= deadline {
      Issue.record("Timed out waiting for: \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}
