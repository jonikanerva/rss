import Foundation
import Testing

@testable import Feeder

actor ClassificationTransportRecorder {
  private(set) var requests: [URLRequest] = []
  private let response: ClassificationHTTPResponse

  init(data: Data, status: Int = 200, retryAfter: String? = nil) {
    response = ClassificationHTTPResponse(data: data, statusCode: status, retryAfter: retryAfter)
  }

  func send(_ request: URLRequest) -> ClassificationHTTPResponse {
    requests.append(request)
    return response
  }
}

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
    let provider = VercelClassificationProvider(apiKey: "fake-vercel-key", send: { await recorder.send($0) })
    let result = try await provider.classify(
      title: "Title", body: "Article text", url: "https://private.invalid/read-history", categories: categories)
    #expect(result == .choice(category: "tech"))
    let request = try #require(await recorder.requests.first)
    #expect(request.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/evaluate")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-vercel-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.timeoutInterval == 30)
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
    let provider = VercelClassificationProvider(apiKey: " \n", send: { await recorder.send($0) })
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
    let provider = VercelClassificationProvider(apiKey: "fake", send: { await recorder.send($0) })
    do {
      _ = try await provider.classify(title: "Title", body: "Body", url: "", categories: categories)
      Issue.record("Expected a rate limit")
    } catch let error as VercelClassificationError {
      #expect(error.batchAbort == .rateLimited)
      #expect(error.retryDisposition == .transient(retryAfter: 3600))
    } catch { Issue.record("Unexpected error: \(error)") }
    #expect(await recorder.requests.count == 1)
  }

  @Test
  func choiceBypassesGenerativeHeuristics() throws {
    let input = ClassificationInput(entryID: 1, title: "Swift Apple", body: "Technology news", url: "")
    let fallback = try resolveClassification(.choice(category: uncategorizedLabel), input: input, categories: categories)
    #expect(fallback.categoryLabel == uncategorizedLabel)
    #expect(fallback.confidence == nil)
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
    for expected in [30, 60, 120, 300, 300] { #expect(state.delay(after: failure) == .seconds(expected)) }
    #expect(state.delay(after: .aborted(.transient(retryAfter: 600), completed: 1)) == .seconds(600))
    #expect(state.delay(after: failure) == .seconds(60))
    #expect(state.delay(after: .completed(1)) == .seconds(2))
    #expect(state.delay(after: failure) == .seconds(30))
    #expect(state.delay(after: .aborted(.blocked, completed: 0)) == nil)
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

  @Test(arguments: [429, 500, 502, 503, 599])
  func httpStatusTakesTheBoundedBackoff(status: Int) {
    #expect(ClassificationRetry(httpStatus: status, retryAfter: 45) == .transient(retryAfter: 45))
  }

  @Test(arguments: [199, 200, 300, 399, 400, 401, 402, 403, 404, 422, 499, 600, 700])
  func otherHTTPStatusesBlock(status: Int) {
    #expect(ClassificationRetry(httpStatus: status, retryAfter: 45) == .blocked)
  }
}
