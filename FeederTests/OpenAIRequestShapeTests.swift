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

  private func classify(through recorder: ClassificationTransportRecorder) async throws -> ProviderClassificationResult {
    let provider = OpenAIClassificationProvider(apiKey: "fake-openai-key", model: "gpt-test", send: { try await recorder.send($0) })
    return try await provider.classify(
      title: "Title", body: "Article text", url: "https://private.invalid/read-history", categories: categories)
  }

  private func failure(through recorder: ClassificationTransportRecorder) async -> OpenAIError? {
    await #expect(throws: OpenAIError.self) { try await classify(through: recorder) }
  }

  @Test
  func requestUsesTheCloudRequestPolicy() async throws {
    let recorder = ClassificationTransportRecorder(data: success)
    #expect(try await classify(through: recorder) == .generative(category: "tech", confidence: 0.9))
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
  func rejectedKeyBlocks() async {
    let recorder = ClassificationTransportRecorder(data: Data(), status: 401)
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == .keyRejected)
    #expect(error?.retryDisposition == .blocked)
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func rateLimitCarriesRetryAfter() async {
    let recorder = ClassificationTransportRecorder(data: Data(), status: 429, retryAfter: "120")
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == .rateLimited)
    #expect(error?.retryDisposition == .transient(retryAfter: 120))
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func serverErrorIsTransient() async {
    let recorder = ClassificationTransportRecorder(data: Data(), status: 503)
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == .providerUnavailable)
    #expect(error?.retryDisposition == .transient(retryAfter: nil))
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func perArticleRejectionKeepsThePerEntryFallback() async {
    let rejection = Data(#"{"error":{"message":"too long","type":"invalid_request_error","code":"context_length_exceeded"}}"#.utf8)
    let recorder = ClassificationTransportRecorder(data: rejection, status: 400)
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == nil)
    #expect(error?.retryDisposition == .poll)
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func lostConnectionIsOffline() async {
    let recorder = ClassificationTransportRecorder(script: [.failure(URLError(.networkConnectionLost))])
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == .offline)
    #expect(error?.retryDisposition == .transient(retryAfter: nil))
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func cancellationIsNotANetworkFailure() async {
    let recorder = ClassificationTransportRecorder(script: [.failure(URLError(.cancelled))])
    await #expect(throws: CancellationError.self) { try await classify(through: recorder) }
  }

  @Test
  func nonHTTPResponseKeepsThePerEntryFallback() async {
    let recorder = ClassificationTransportRecorder(failure: CloudSession.NonHTTPResponse())
    let error = await failure(through: recorder)
    #expect(error?.batchAbort == nil)
    #expect(error?.retryDisposition == .poll)
    #expect(await recorder.requests.count == 1)
  }
}
