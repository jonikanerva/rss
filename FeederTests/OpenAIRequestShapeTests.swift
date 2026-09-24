import Foundation
import Testing

@testable import Feeder

// MARK: - OpenAI request wire shape

/// Regression pin for the field-tested gpt-5.6-luna failure: the model
/// rejects `temperature: 0` with a deterministic 400 ("Only the default (1)
/// value is supported"), which — before the abort path — would have burned
/// the corpus to Uncategorized. The maximally compatible request shape
/// sends NO sampling parameters and lets each model's default apply, so
/// this test fails if anyone reintroduces a `temperature` key.
@Suite("OpenAI request shape")
struct OpenAIRequestShapeTests {
  @Test
  func encodedRequestBodyOmitsTemperature() throws {
    let body = try OpenAIClassificationProvider.encodeRequestBody(
      model: "gpt-5.6-luna",
      instructions: "Classify the article.",
      userMessage: "title: Example\ncontent: body"
    )

    let object = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["temperature"] == nil, "Request must not send a temperature key")

    // The load-bearing keys are still present.
    #expect(object["model"] as? String == "gpt-5.6-luna")
    #expect(object["messages"] is [[String: Any]])
    #expect(object["response_format"] is [String: Any])
  }
}

// MARK: - OpenAI classification transport

@Suite("OpenAI classification transport")
struct OpenAIClassificationTransportTests {
  private let categories = [
    CategoryDefinition(label: "tech", description: "Technology news"),
    CategoryDefinition(label: uncategorizedLabel, description: "No matching category"),
  ]
  private let success = Data(#"{"choices":[{"message":{"content":"{\"category\":\"tech\",\"confidence\":0.9}"}}]}"#.utf8)

  private func classify(
    through recorder: ClassificationTransportRecorder, retryClock: ClassificationSleepRecorder
  ) async throws -> ProviderClassificationResult {
    let provider = OpenAIClassificationProvider(
      apiKey: "fake-openai-key", model: "gpt-test", send: { try await recorder.send($0) }, sleep: { try await retryClock.sleep($0) })
    return try await provider.classify(
      title: "Title", body: "Article text", url: "https://private.invalid/read-history", categories: categories)
  }

  private func failure(
    through recorder: ClassificationTransportRecorder, retryClock: ClassificationSleepRecorder
  ) async -> OpenAIError? {
    await #expect(throws: OpenAIError.self) { try await classify(through: recorder, retryClock: retryClock) }
  }

  @Test
  func requestUsesTheCloudRequestPolicy() async throws {
    let recorder = ClassificationTransportRecorder(data: success)
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(try await classify(through: recorder, retryClock: clock) == .generative(category: "tech", confidence: 0.9))
    let requests = await recorder.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-openai-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 60)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("Article text"))
    #expect(!body.contains("private.invalid"))
    #expect(!body.contains("fake-openai-key"))
  }

  @Test
  func missingKeySendsNothing() async {
    let recorder = ClassificationTransportRecorder(data: success)
    let provider = OpenAIClassificationProvider(apiKey: "", model: "gpt-test", send: { try await recorder.send($0) })
    let error = await #expect(throws: OpenAIError.self) {
      try await provider.classify(title: "Title", body: "Article text", url: "", categories: categories)
    }
    switch error {
    case .needsKey?: break
    default: Issue.record("Expected OpenAIError.needsKey, got \(String(describing: error))")
    }
    #expect(error?.batchAbort == .needsKey)
    #expect(error?.retryDisposition == .poll)
    #expect(await recorder.requests.isEmpty)
  }

  @Test
  func rejectedKeyBlocks() async {
    let recorder = ClassificationTransportRecorder(data: Data(), status: 401)
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == .keyRejected)
    #expect(error?.retryDisposition == .blocked)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test(arguments: OpenAIErrorBodies.rateLimit)
  func rateLimitCarriesRetryAfter(body: String) async {
    let recorder = ClassificationTransportRecorder(data: Data(body.utf8), status: 429, retryAfter: "20")
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == .rateLimited)
    #expect(error?.retryDisposition == .transient(retryAfter: 20))
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func retryAfterAtTheLimitIsWaitedInsideTheRequestRetry() async throws {
    let recorder = ClassificationTransportRecorder(script: [
      .success(.status(429, retryAfter: "10")), .success(.status(200, data: success)),
    ])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    #expect(try await classify(through: recorder, retryClock: clock) == .generative(category: "tech", confidence: 0.9))
    #expect(await recorder.requests.count == 2)
    #expect(await clock.delays == [.seconds(10)])
  }

  /// A billing failure gets no request retry (`STACK.md → Cloud classification`).
  @Test(arguments: OpenAIErrorBodies.billing)
  func billingFailureBlocks(body: String) async {
    let recorder = ClassificationTransportRecorder(data: Data(body.utf8), status: 429, retryAfter: "120")
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == .quotaExhausted)
    #expect(error?.retryDisposition == .blocked)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func quotaAfterServerErrorSendsTwoRequests() async throws {
    let billing = try #require(OpenAIErrorBodies.billing.first)
    let recorder = ClassificationTransportRecorder(script: [
      .success(.status(503)), .success(.status(429, data: Data(billing.utf8))),
    ])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == .quotaExhausted)
    #expect(error?.retryDisposition == .blocked)
    #expect(await recorder.requests.count == 2)
    #expect(await clock.delays == [.seconds(2)])
  }

  @Test
  func perArticleRejectionKeepsThePerEntryFallback() async {
    let rejection = Data(#"{"error":{"message":"too long","type":"invalid_request_error","code":"context_length_exceeded"}}"#.utf8)
    let recorder = ClassificationTransportRecorder(data: rejection, status: 400)
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == nil)
    #expect(error?.retryDisposition == .poll)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }

  @Test
  func cancellationIsNotANetworkFailure() async {
    let recorder = ClassificationTransportRecorder(script: [.failure(URLError(.cancelled))])
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    await #expect(throws: CancellationError.self) { try await classify(through: recorder, retryClock: clock) }
  }

  @Test
  func nonHTTPResponseKeepsThePerEntryFallback() async {
    let recorder = ClassificationTransportRecorder(failure: CloudSession.NonHTTPResponse())
    let clock = ClassificationSleepRecorder(immediateDelays: .max)
    let error = await failure(through: recorder, retryClock: clock)
    #expect(error?.batchAbort == nil)
    #expect(error?.retryDisposition == .poll)
    #expect(await recorder.requests.count == 1)
    #expect(await clock.delays.isEmpty)
  }
}
