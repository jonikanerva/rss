import Foundation
import Testing

// MARK: - Async polling helper

/// Poll `condition` until it returns `true` or the timeout elapses. It records
/// an issue on timeout without throwing, so the calling test decides whether to
/// assert on the post-condition state too.
///
/// `description` is interpolated into that timeout message, so the failure stays
/// specific even though the helper is generic. The closure is `@Sendable`, so a
/// caller reads actor state without crossing isolation by hand.
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
