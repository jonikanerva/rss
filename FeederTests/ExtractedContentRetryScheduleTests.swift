import Foundation
import Testing

@testable import Feeder

@Suite("Extracted content retry schedule")
struct ExtractedContentRetryScheduleTests {
  private static let start = Date(timeIntervalSince1970: 1_700_000_000)
  private static let minute: TimeInterval = 60

  @Test
  func failedEntryWaitsFifteenMinutes() {
    var schedule = ExtractedContentRetrySchedule()
    #expect(schedule.isDue(1, now: Self.start))

    schedule.record(.failure(.http(status: 404)), for: 1, now: Self.start)

    #expect(!schedule.isDue(1, now: Self.start.addingTimeInterval(15 * Self.minute - 1)))
    #expect(schedule.isDue(1, now: Self.start.addingTimeInterval(15 * Self.minute)))
    #expect(schedule.isDue(2, now: Self.start))
  }

  @Test
  func delayDoublesUpToSixHours() {
    let delays = (1...7).map { ExtractedContentRetrySchedule.delay(afterFailures: $0) / Self.minute }
    #expect(delays == [15, 30, 60, 120, 240, 360, 360])
  }

  @Test
  func consecutiveFailuresUseTheLongerDelay() {
    var schedule = ExtractedContentRetrySchedule()
    schedule.record(.failure(.noContent), for: 1, now: Self.start)
    let retry = Self.start.addingTimeInterval(15 * Self.minute)

    schedule.record(.failure(.transport(.timedOut)), for: 1, now: retry)

    #expect(!schedule.isDue(1, now: retry.addingTimeInterval(30 * Self.minute - 1)))
    #expect(schedule.isDue(1, now: retry.addingTimeInterval(30 * Self.minute)))
  }

  @Test
  func successForgetsTheFailures() {
    var schedule = ExtractedContentRetrySchedule()
    schedule.record(.failure(.undecodable), for: 1, now: Self.start)
    schedule.record(.success(()), for: 1, now: Self.start)
    #expect(schedule.isDue(1, now: Self.start))

    schedule.record(.failure(.undecodable), for: 1, now: Self.start)
    #expect(schedule.isDue(1, now: Self.start.addingTimeInterval(15 * Self.minute)))
  }

  @Test(arguments: [
    ExtractedContentFailure.cancelled, .http(status: 429), .transport(.notConnectedToInternet),
    .transport(.cannotFindHost), .transport(.cannotConnectToHost), .transport(.dnsLookupFailed),
  ])
  func cancellationAndHostFailuresRecordNothing(_ failure: ExtractedContentFailure) {
    var schedule = ExtractedContentRetrySchedule()
    schedule.record(.failure(failure), for: 1, now: Self.start)
    #expect(schedule.isDue(1, now: Self.start))

    schedule.record(.failure(.http(status: 404)), for: 1, now: Self.start)
    schedule.record(.failure(failure), for: 1, now: Self.start)
    #expect(schedule.isDue(1, now: Self.start.addingTimeInterval(15 * Self.minute)))
  }

  @Test(arguments: [
    ExtractedContentFailure.http(status: 429), .transport(.notConnectedToInternet), .transport(.cannotFindHost),
    .transport(.cannotConnectToHost), .transport(.dnsLookupFailed),
  ])
  func hostFailuresStopTheBatch(_ failure: ExtractedContentFailure) {
    #expect(failure.stopsBatch)
  }

  @Test(arguments: [
    ExtractedContentFailure.http(status: 404), .http(status: 503), .undecodable, .noContent, .cancelled,
    .transport(.timedOut), .transport(.networkConnectionLost), .transport(.badURL),
  ])
  func entryFailuresDoNotStopTheBatch(_ failure: ExtractedContentFailure) {
    #expect(!failure.stopsBatch)
  }
}
