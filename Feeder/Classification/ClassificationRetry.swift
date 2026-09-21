import Foundation

nonisolated enum ClassificationRetry: Sendable, Equatable {
  case poll
  case transient(retryAfter: TimeInterval?)
  case blocked
}

nonisolated enum ClassificationBatchOutcome: Sendable {
  case completed(Int)
  case aborted(ClassificationRetry, completed: Int)
  case cancelled
}

nonisolated struct ClassificationRetryState: Sendable {
  private var failures = 0

  /// Nil means that only an explicit retry or configuration change may send again.
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
      case .blocked: return nil
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
