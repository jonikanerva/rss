import Foundation
import Testing

@testable import Feeder

@Suite("Vercel JEV wire and limits")
struct VercelClassificationTests {
  private let categories = [
    CategoryDefinition(label: "tech", description: "Technology news", folderLabel: "private-folder", keywords: ["Swift", "Apple"]),
    CategoryDefinition(label: uncategorizedLabel, description: "No matching category"),
  ]
  private let success = Data(
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"tech":0.1,"uncategorized":0.1}}}}"#.utf8)

  @Test
  func exactWireUsesOwnKeyAndOnlyAllowedData() async throws {
    let recorder = ClassificationTransportRecorder(data: success)
    let provider = VercelClassificationProvider(apiKey: "fake-vercel-key", send: { try await recorder.send($0) })
    let result = try await provider.classify(
      title: "Title", body: "Article text", url: "https://private.invalid/read-history", categories: categories)
    #expect(result == .choice(category: "tech"))
    let request = try #require(await recorder.requests.first)
    #expect(request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/evaluate")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-vercel-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 30)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    let data = try #require(request.httpBody)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(root.keys) == ["model", "state", "questions"])
    #expect(root["model"] as? String == "typesafe-ai/jev")
    let state = try #require(root["state"] as? [String: String])
    #expect(state == ["title": "Title", "content": "Article text"])
    let questions = try #require(root["questions"] as? [String: [String: Any]])
    #expect(Set(questions.keys) == ["category"])
    #expect(questions["category"]?["type"] as? String == "choice")
    let criteria = try #require(questions["category"]?["criteria"] as? [String: String])
    #expect(criteria.count == 2)
    #expect(criteria["tech"] == "Technology news\nKeywords: Swift, Apple")
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("private-folder"))
    #expect(!text.contains("private.invalid"))
    #expect(!text.contains("fake-vercel-key"))
  }

  @Test
  func choiceLimitIncludesOneFallback() throws {
    let definitions = (0..<254).map { CategoryDefinition(label: "c\($0)", description: "Category \($0)") }
    #expect(try VercelClassificationProvider.makeCriteria(definitions).count == 255)
    #expect(try VercelClassificationProvider.makeCriteria(definitions + [categories[1]]).count == 255)
    #expect(throws: VercelClassificationError.self) {
      try VercelClassificationProvider.makeCriteria(definitions + [CategoryDefinition(label: "extra", description: "Extra")])
    }
  }

  @Test
  func duplicateAndEmptyLabelsAreRejected() {
    for definitions in [
      [categories[0], categories[0]], [CategoryDefinition(label: " \n", description: "Empty")], [categories[1], categories[1]],
    ] {
      #expect(throws: VercelClassificationError.self) { try VercelClassificationProvider.makeCriteria(definitions) }
    }
  }

  @Test
  func byteLimitKeepsUnicodeAndCompleteMetadata() throws {
    let body = String(repeating: "🧑🏽‍💻Å漢字\n\"\\", count: 5000)
    let data = try VercelClassificationProvider.requestBody(title: String(repeating: "界", count: 900), body: body, categories: categories)
    #expect(data.count <= VercelClassificationProvider.maximumRequestBytes)
    #expect(data.count > 23_900)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let state = try #require(root["state"] as? [String: String])
    #expect(state["title"]?.count == 512)
    #expect(body.hasPrefix(try #require(state["content"])))
    #expect(!String(decoding: data, as: UTF8.self).contains("�"))
  }

  @Test
  func oversizedTaxonomyFailsWithoutTruncation() {
    let large = [CategoryDefinition(label: "large", description: String(repeating: "x", count: 24_000))]
    #expect(throws: VercelClassificationError.self) {
      try VercelClassificationProvider.requestBody(title: "", body: "", categories: large)
    }
  }

  @Test
  func lowProbabilityAndTiedChoiceRemainValid() throws {
    #expect(try VercelClassificationProvider.decode(success, categories: categories) == .choice(category: "tech"))
    let fallback = Data(
      #"{"answers":{"category":{"type":"choice","choice":"uncategorized","probabilities":{"tech":0.9,"uncategorized":0.1}}}}"#.utf8)
    #expect(try VercelClassificationProvider.decode(fallback, categories: categories) == .choice(category: uncategorizedLabel))
  }

  @Test(arguments: [
    #"{"answers":{"other":{"type":"choice","choice":"tech","probabilities":{"tech":1}}}}"#,
    #"{"answers":{"category":{"type":"boolean","choice":"tech","probabilities":{"tech":1}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"unknown","probabilities":{"tech":1}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"unknown":1}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"tech":-0.1}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"tech":1.1}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{}}}}"#,
    #"{"answers":{"category":{"type":"choice","choice":"tech","probabilities":{"tech":1e999}}}}"#,
    #"{}"#,
  ])
  func malformedAnswersStopClassification(_ json: String) {
    #expect(throws: VercelClassificationError.self) {
      try VercelClassificationProvider.decode(Data(json.utf8), categories: categories)
    }
  }

  @Test
  func missingKeySendsNothing() async {
    let recorder = ClassificationTransportRecorder(data: success)
    let provider = VercelClassificationProvider(apiKey: " \n", send: { try await recorder.send($0) })
    await #expect(throws: VercelClassificationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    #expect(await recorder.requests.isEmpty)
  }

  @Test
  func cancellationIsNotANetworkFailure() async {
    let provider = VercelClassificationProvider(apiKey: "fake", send: { _ in throw URLError(.cancelled) })
    await #expect(throws: CancellationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
  }

  @Test
  func rateLimitCarriesBoundedRetryAfter() async {
    let recorder = ClassificationTransportRecorder(data: Data(), status: 429, retryAfter: "7200")
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { try await recorder.send($0) }, sleep: { try await clock.sleep($0) })
    do {
      _ = try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
      Issue.record("Expected a rate limit")
    } catch let error as VercelClassificationError {
      #expect(error.batchAbort == .rateLimited)
      #expect(error.retryDisposition == .transient(retryAfter: 3600))
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test(arguments: [VercelErrorBodies.budgetExceeded, ""], [nil, "120"] as [String?])
  func billingFailureBlocksWithoutARequestRetry(body: String, retryAfter: String?) async {
    let recorder = ClassificationTransportRecorder(data: Data(body.utf8), status: 402, retryAfter: retryAfter)
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { try await recorder.send($0) }, sleep: { try await clock.sleep($0) })
    let error = await #expect(throws: VercelClassificationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    #expect(error?.batchAbort == .quotaExhausted)
    #expect(error?.retryDisposition == .blocked)
    #expect(error?.isSkippable == false)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func requestTimeoutIsAProviderOutage() {
    let error = VercelClassificationError.http(408, retryAfter: nil)
    #expect(error.batchAbort == .providerUnavailable)
    #expect(error.retryDisposition == .transient(retryAfter: nil))
  }

  @Test
  func shortRetryAfterExtendsTheRequestRetryWait() async throws {
    let recorder = ClassificationTransportRecorder(script: [
      .success(.status(503, retryAfter: "3")), .success(.status(429, retryAfter: "7")), .success(.status(200, data: success)),
    ])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { try await recorder.send($0) }, sleep: { try await clock.sleep($0) })
    let result = try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    #expect(result == .choice(category: "tech"))
    #expect(await recorder.requests.count == 3)
    #expect(await clock.delays == [.seconds(3), .seconds(7)])
  }

  @Test
  func lastAttemptPassesRetryAfterToTheLoop() async {
    let recorder = ClassificationTransportRecorder(script: [
      .success(.status(503)), .success(.status(503)), .success(.status(503, retryAfter: "5")),
    ])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { try await recorder.send($0) }, sleep: { try await clock.sleep($0) })
    let error = await #expect(throws: VercelClassificationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    #expect(error?.batchAbort == .providerUnavailable)
    #expect(error?.retryDisposition == .transient(retryAfter: 5))
    #expect(await recorder.requests.count == 3)
    #expect(await clock.delays == [.seconds(2), .seconds(4)])
  }

  @Test
  func nonHTTPResponseIsAnInvalidResponse() async {
    let recorder = ClassificationTransportRecorder(failure: CloudSession.NonHTTPResponse())
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { try await recorder.send($0) }, sleep: { try await clock.sleep($0) })
    let error = await #expect(throws: VercelClassificationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    #expect(error?.batchAbort == .invalidResponse)
    #expect(error?.retryDisposition == .blocked)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func transportFailureWithoutAURLErrorIsNotRetried() async {
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let provider = VercelClassificationProvider(
      apiKey: "fake", send: { _ in throw FakeProviderError() }, sleep: { try await clock.sleep($0) })
    let error = await #expect(throws: VercelClassificationError.self) {
      try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
    }
    #expect(error?.batchAbort == .offline)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func choiceBypassesGenerativeHeuristics() throws {
    let input = ClassificationInput(entryID: 1, title: "Swift Apple", body: "Technology news", url: "")
    let fallback = try resolveClassification(.choice(category: uncategorizedLabel), input: input, categories: categories)
    #expect(fallback.categoryLabel == uncategorizedLabel)
    let direct = try resolveClassification(.choice(category: "tech"), input: input, categories: categories)
    #expect(direct.categoryLabel == "tech")
    let plain = ClassificationInput(entryID: 1, title: "Unrelated", body: "Unrelated", url: "")
    let generative = try resolveClassification(.generative(category: "tech", confidence: 0.1), input: plain, categories: categories)
    #expect(generative.categoryLabel == uncategorizedLabel)
  }

  @Test
  func openAIArticleMessageExcludesURL() {
    #expect(OpenAIClassificationProvider.articleMessage(title: "Title", body: "Body") == "title: Title\ncontent: Body")
  }
}

@Suite("Classification retry policy")
struct ClassificationRetryTests {
  @Test
  func exponentialDelaySurvivesBatchesAndProgressResetsIt() {
    var state = ClassificationRetryState()
    let failure = ClassificationBatchOutcome.aborted(.transient(retryAfter: nil), completed: 0)
    for expected in [10, 20, 40, 80, 160, 300, 300] { #expect(state.delay(after: failure) == .seconds(expected)) }
    #expect(state.delay(after: .aborted(.transient(retryAfter: 600), completed: 1)) == .seconds(600))
    #expect(state.delay(after: failure) == .seconds(20))
    #expect(state.delay(after: .completed(1)) == .seconds(2))
    #expect(state.delay(after: failure) == .seconds(10))
    #expect(state.delay(after: .aborted(.blocked, completed: 0)) == .seconds(3600))
  }

  @Test
  func blockedRechecksHourlyAndOnlyCancellationStops() {
    var state = ClassificationRetryState()
    for _ in 0..<3 { #expect(state.delay(after: .aborted(.blocked, completed: 0)) == .seconds(3600)) }
    #expect(state.delay(after: .cancelled) == nil)
  }

  @Test
  func retryAfterParsesUTCAndRejectsInvalidValues() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(retryAfterDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: now) == 120)
    #expect(retryAfterDelay("999999", now: now) == 3600)
    #expect(retryAfterDelay("0", now: now) == 0)
    #expect(retryAfterDelay(nil, now: now) == nil)
    #expect(retryAfterDelay("-1", now: now) == nil)
    #expect(retryAfterDelay("NaN", now: now) == nil)
    #expect(retryAfterDelay("bad", now: now) == nil)
  }

  @Test(arguments: [408, 429, 500, 502, 503, 599])
  func httpStatusTakesTheBoundedBackoff(status: Int) {
    #expect(ClassificationRetry(httpStatus: status, retryAfter: 45) == .transient(retryAfter: 45))
  }

  @Test(arguments: [199, 200, 300, 399, 400, 401, 402, 403, 404, 407, 409, 422, 499, 600, 700])
  func otherHTTPStatusesBlock(status: Int) {
    #expect(ClassificationRetry(httpStatus: status, retryAfter: 45) == .blocked)
  }

  @Test
  func onlyATransientFailureWithoutRetryAfterOrServiceLimitIsSkippable() {
    let skippable: [any ClassificationFailure] = [
      VercelClassificationError.network, VercelClassificationError.http(503, retryAfter: nil),
      VercelClassificationError.http(408, retryAfter: nil), OpenAIError.networkUnavailable(underlying: URLError(.timedOut)),
      OpenAIError.apiError(statusCode: 500, message: "x", retryAfter: nil),
    ]
    for failure in skippable { #expect(failure.isSkippable, "\(failure) must be skippable") }
    let stopping: [any ClassificationFailure] = [
      VercelClassificationError.http(503, retryAfter: 5), VercelClassificationError.http(503, retryAfter: 0),
      VercelClassificationError.http(429, retryAfter: nil), VercelClassificationError.http(402, retryAfter: nil),
      VercelClassificationError.http(402, retryAfter: 120), VercelClassificationError.http(401, retryAfter: nil),
      VercelClassificationError.invalidResponse,
      OpenAIError.apiError(statusCode: 429, message: "x", retryAfter: nil), OpenAIError.quotaExhausted(code: nil),
      OpenAIError.entryRejected(code: "context_length_exceeded"), OpenAIError.needsKey,
      FakeClassificationFailure(batchAbort: .offline), FakeClassificationFailure(batchAbort: nil),
    ]
    for failure in stopping { #expect(!failure.isSkippable, "\(failure) must not be skippable") }
  }

  @Test
  func unknownArticleIsNeitherSentLastNorFallback() {
    let failures = TransientEntryFailures()
    #expect(!failures.sendsLast(1))
    #expect(!failures.requiresFallback(1))
    #expect(failures.strikes(for: 1) == 0)
  }

  @Test
  func drainWithoutASuccessMarksButGivesNoStrike() {
    var failures = TransientEntryFailures()
    for _ in 0..<10 { failures.record(failedIDs: [1, 2], anotherEntrySucceeded: false) }
    #expect(failures.sendsLast(1))
    #expect(failures.sendsLast(2))
    #expect(failures.strikes(for: 1) == 0)
    #expect(!failures.requiresFallback(1))
    #expect(failures != TransientEntryFailures())
  }

  @Test
  func thirdCountedDrainRequiresTheFallback() {
    var failures = TransientEntryFailures()
    for strike in 1..<TransientEntryFailures.fallbackDrainCount {
      failures.record(failedIDs: [1], anotherEntrySucceeded: true)
      #expect(failures.strikes(for: 1) == strike)
      #expect(failures.sendsLast(1))
      #expect(!failures.requiresFallback(1))
    }
    failures.record(failedIDs: [1], anotherEntrySucceeded: false)
    #expect(!failures.requiresFallback(1))
    failures.record(failedIDs: [1], anotherEntrySucceeded: true)
    #expect(TransientEntryFailures.fallbackDrainCount == 3)
    #expect(failures.strikes(for: 1) == 3)
    #expect(failures.requiresFallback(1))
    #expect(!failures.sendsLast(1))
  }

  @Test
  func recordChangesOnlyTheFailedArticles() {
    var failures = TransientEntryFailures()
    failures.record(failedIDs: [1], anotherEntrySucceeded: true)
    failures.record(failedIDs: [], anotherEntrySucceeded: true)
    #expect(failures.strikes(for: 1) == 1)
    #expect(failures.strikes(for: 2) == 0)
    #expect(!failures.sendsLast(2))
    var unchanged = TransientEntryFailures()
    unchanged.record(failedIDs: [], anotherEntrySucceeded: true)
    #expect(unchanged == TransientEntryFailures())
  }
}

@Suite("Cloud request retry")
struct CloudRequestRetryTests {
  @Test(arguments: [
    CloudRequestFailure.http(status: 408, retryAfter: nil), .http(status: 429, retryAfter: nil), .http(status: 500, retryAfter: nil),
    .http(status: 503, retryAfter: nil), .http(status: 599, retryAfter: nil), .transport(.networkConnectionLost),
  ])
  func healableFailureWaitsTwiceThenStops(_ failure: CloudRequestFailure) {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: failure) == .seconds(2))
    #expect(CloudRequestRetry.delay(afterAttempt: 2, failure: failure) == .seconds(4))
    #expect(CloudRequestRetry.delay(afterAttempt: 3, failure: failure) == nil)
  }

  @Test
  func timeoutRetriesOnce() {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .transport(.timedOut)) == .seconds(2))
    #expect(CloudRequestRetry.delay(afterAttempt: 2, failure: .transport(.timedOut)) == nil)
  }

  @Test(arguments: [300, 399, 400, 401, 402, 403, 404, 407, 409, 422, 499, 600])
  func otherHTTPStatusStopsAtOnce(status: Int) {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: status, retryAfter: nil)) == nil)
  }

  @Test(arguments: [
    URLError.Code.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .secureConnectionFailed, .cancelled,
  ])
  func otherTransportFailureStopsAtOnce(_ code: URLError.Code) {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .transport(code)) == nil)
  }

  @Test
  func shortRetryAfterExtendsThePlannedWait() {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 429, retryAfter: 3)) == .seconds(3))
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 503, retryAfter: 10)) == .seconds(10))
    #expect(CloudRequestRetry.delay(afterAttempt: 2, failure: .http(status: 503, retryAfter: 10)) == .seconds(10))
  }

  @Test
  func plannedWaitWinsOverAShorterRetryAfter() {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 503, retryAfter: 0)) == .seconds(2))
    #expect(CloudRequestRetry.delay(afterAttempt: 2, failure: .http(status: 503, retryAfter: 3)) == .seconds(4))
  }

  @Test
  func longRetryAfterStopsAtOnce() {
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 429, retryAfter: 11)) == nil)
    #expect(CloudRequestRetry.delay(afterAttempt: 2, failure: .http(status: 503, retryAfter: 11)) == nil)
    #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 503, retryAfter: 3600)) == nil)
  }

  @Test
  func invalidRetryAfterCountsAsAbsent() {
    let invalidValues: [TimeInterval] = [-1, .nan, .infinity]
    for value in invalidValues {
      #expect(CloudRequestRetry.delay(afterAttempt: 1, failure: .http(status: 503, retryAfter: value)) == .seconds(2))
    }
  }

  @Test
  func retryAfterLimitIsTheFirstLoopWait() {
    var state = ClassificationRetryState()
    let firstLoopWait = state.delay(after: .aborted(.transient(retryAfter: nil), completed: 0))
    #expect(firstLoopWait == .seconds(CloudRequestRetry.longestRetryAfter))
    #expect(CloudRequestRetry.longestRetryAfter == 10)
  }
}
