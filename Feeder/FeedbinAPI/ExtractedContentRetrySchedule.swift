import Foundation

extension ExtractedContentFailure {
  /// True for a failure of the extract host, not of one entry. `SyncEngine`
  /// stops the extracted-content batch before its next chunk of requests, and
  /// `ExtractedContentRetrySchedule` records nothing.
  nonisolated var stopsBatch: Bool {
    switch self {
    case .http(let status):
      status == 429
    case .transport(let code):
      [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains(code)
    case .undecodable, .noContent, .cancelled:
      false
    }
  }
}

extension ExtractedContentFailure {
  /// True when the extract host rejects the request of one entry on every
  /// attempt. `SyncEngine` clears the `extractedContentURL` of that entry.
  nonisolated var isPermanent: Bool {
    switch self {
    case .http(let status):
      status == 400 || status == 410
    case .transport, .undecodable, .noContent, .cancelled:
      false
    }
  }
}

/// Keep the schedule in memory only: Feeder persists nothing about a failed
/// extracted-content request.
nonisolated struct ExtractedContentRetrySchedule: Sendable {
  private static let firstDelay: TimeInterval = 15 * 60
  private static let longestDelay: TimeInterval = 6 * 60 * 60

  private struct Failures: Sendable {
    let count: Int
    let retryAt: Date
  }

  private var failuresByEntryID: [Int: Failures] = [:]

  /// `count` is the number of consecutive failures of one entry, from 1.
  static func delay(afterFailures count: Int) -> TimeInterval {
    min(firstDelay * pow(2, Double(max(count - 1, 0))), longestDelay)
  }

  func isDue(_ entryID: Int, now: Date) -> Bool {
    guard let failures = failuresByEntryID[entryID] else { return true }
    return now >= failures.retryAt
  }

  mutating func record(_ outcome: Result<Void, ExtractedContentFailure>, for entryID: Int, now: Date) {
    switch outcome {
    case .success:
      failuresByEntryID[entryID] = nil
    case .failure(let failure) where failure == .cancelled || failure.stopsBatch:
      break
    case .failure:
      let count = (failuresByEntryID[entryID]?.count ?? 0) + 1
      failuresByEntryID[entryID] = Failures(
        count: count, retryAt: now.addingTimeInterval(Self.delay(afterFailures: count)))
    }
  }
}
