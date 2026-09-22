import Foundation

nonisolated enum ClassificationRetry: Sendable, Equatable {
  case poll
  case transient(retryAfter: TimeInterval?)
  case blocked

  /// The HTTP retry rule both cloud providers share (`STACK.md → Cloud
  /// classification`): a rate limit and a server error take the bounded
  /// backoff, and every other status blocks.
  init(httpStatus: Int, retryAfter: TimeInterval?) {
    if httpStatus == 429 || (500...599).contains(httpStatus) {
      self = .transient(retryAfter: retryAfter)
    } else {
      self = .blocked
    }
  }
}

/// Reads an HTTP `Retry-After` value as a delay in seconds, bounded to one hour
/// (`STACK.md → Cloud classification`). An absent or invalid value returns nil.
/// `now` is a parameter because the HTTP-date form is relative to the caller.
nonisolated func retryAfterDelay(_ value: String?, now: Date) -> TimeInterval? {
  guard let value else { return nil }
  if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return min(seconds, 3600) }
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
  guard let date = formatter.date(from: value) else { return nil }
  return min(max(0, date.timeIntervalSince(now)), 3600)
}

nonisolated enum ClassificationBatchOutcome: Sendable {
  case completed(Int)
  case aborted(ClassificationRetry, completed: Int)
  case cancelled
}

nonisolated struct ClassificationRetryState: Sendable {
  private var failures = 0

  /// Nil means the caller must stop the loop. A blocked outcome waits one hour
  /// and then sends again, so a blocking failure never stops the drain for
  /// good. The caller may cancel any wait.
  mutating func delay(after outcome: ClassificationBatchOutcome) -> Duration? {
    switch outcome {
    case .completed:
      failures = 0
      return .seconds(2)
    case .cancelled:
      return nil
    case .aborted(let retry, let completed):
      if completed > 0 { failures = 0 }
      switch retry {
      case .poll: return .seconds(2)
      case .blocked: return .seconds(3600)
      case .transient(let retryAfter):
        let schedule: [TimeInterval] = [30, 60, 120, 300]
        let delay = schedule[min(failures, schedule.count - 1)]
        failures = min(failures + 1, schedule.count - 1)
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? min($0, 3600) : nil } ?? 0
        return .seconds(max(delay, serverDelay))
      }
    }
  }
}
