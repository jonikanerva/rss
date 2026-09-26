import Foundation

nonisolated enum ClassificationRetry: Sendable, Equatable {
  case poll
  case transient(retryAfter: TimeInterval?)
  case blocked

  /// The HTTP retry rule both cloud providers share (`STACK.md → Cloud
  /// classification`): a request timeout, a rate limit, and a server error
  /// take the loop backoff, and every other status blocks.
  init(httpStatus: Int, retryAfter: TimeInterval?) {
    self = Self.isTransient(httpStatus: httpStatus) ? .transient(retryAfter: retryAfter) : .blocked
  }

  /// `CloudRequestRetry` reads this predicate too: a change here also changes
  /// the request retry.
  static func isTransient(httpStatus: Int) -> Bool {
    httpStatus == 408 || httpStatus == 429 || (500...599).contains(httpStatus)
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
  return retryAfterDelay(until: date, now: now)
}

/// Bounded to zero through one hour (`STACK.md → Cloud classification`).
nonisolated func retryAfterDelay(until date: Date, now: Date) -> TimeInterval {
  min(max(0, date.timeIntervalSince(now)), 3600)
}

nonisolated enum ClassificationBatchOutcome: Sendable {
  case completed(Int)
  case aborted(ClassificationRetry, completed: Int)
  case cancelled
}

nonisolated struct ClassificationRetryState: Sendable {
  /// `CloudRequestRetry.longestRetryAfter` equals this wait.
  static let firstTransientDelay: TimeInterval = 10
  private static let transientSchedule: [TimeInterval] = [firstTransientDelay, 20, 40, 80, 160, 300]
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
        let schedule = Self.transientSchedule
        let delay = schedule[min(failures, schedule.count - 1)]
        failures = min(failures + 1, schedule.count - 1)
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? min($0, 3600) : nil } ?? 0
        return .seconds(max(delay, serverDelay))
      }
    }
  }
}

extension ClassificationFailure {
  /// True only for a failure after which the drain skips the article and sends
  /// the next one (`STACK.md → Cloud classification`).
  nonisolated var isSkippable: Bool {
    guard let batchAbort, batchAbort != .rateLimited else { return false }
    return retryDisposition == .transient(retryAfter: nil)
  }
}

/// Per-article strikes for the skip rule in `STACK.md → Cloud classification`.
nonisolated struct TransientEntryFailures: Sendable, Equatable {
  static let fallbackDrainCount = 3
  /// A key means that an earlier drain skipped the article.
  private var counts: [Int: Int] = [:]

  func sendsLast(_ entryID: Int) -> Bool {
    guard let count = counts[entryID] else { return false }
    return count < Self.fallbackDrainCount
  }

  /// True means: assign the uncategorized fallback and send no request.
  func requiresFallback(_ entryID: Int) -> Bool {
    strikes(for: entryID) >= Self.fallbackDrainCount
  }

  func strikes(for entryID: Int) -> Int {
    counts[entryID] ?? 0
  }

  /// Marks each failed article. Each one gets a strike only when another
  /// article succeeded in the same drain.
  mutating func record(failedIDs: [Int], anotherEntrySucceeded: Bool) {
    for entryID in failedIDs {
      counts[entryID, default: 0] += anotherEntrySucceeded ? 1 : 0
    }
  }
}

nonisolated enum CloudRequestFailure: Sendable, Equatable {
  /// `retryAfter` comes from `retryAfterDelay(_:now:)`.
  case http(status: Int, retryAfter: TimeInterval?)
  case transport(URLError.Code)
}

nonisolated enum CloudRequestRetry {
  private static let plannedDelays: [TimeInterval] = [2, 4]
  private static let timeoutRetries = 1
  /// A longer valid `Retry-After` stops the drain at once, and the loop honours
  /// the value.
  static let longestRetryAfter = ClassificationRetryState.firstTransientDelay

  /// `attempt` counts sent requests, from 1. Nil means: send no more requests
  /// and throw the failure.
  static func delay(afterAttempt attempt: Int, failure: CloudRequestFailure) -> Duration? {
    guard plannedDelays.indices.contains(attempt - 1) else { return nil }
    let planned = plannedDelays[attempt - 1]
    switch failure {
    case .http(let status, let retryAfter):
      guard ClassificationRetry.isTransient(httpStatus: status) else { return nil }
      guard let retryAfter, retryAfter.isFinite, retryAfter >= 0 else { return .seconds(planned) }
      return retryAfter <= longestRetryAfter ? .seconds(max(planned, retryAfter)) : nil
    case .transport(.timedOut):
      return attempt <= timeoutRetries ? .seconds(planned) : nil
    case .transport(.networkConnectionLost):
      return .seconds(planned)
    case .transport:
      return nil
    }
  }
}
