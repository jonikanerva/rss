import Foundation
import OSLog

/// Classifies articles through the OpenAI Chat Completions API with structured
/// outputs, over `URLSession` and no third-party dependency.
nonisolated struct OpenAIClassificationProvider: ClassificationProvider {
  /// Declared inside the `nonisolated struct`, so the `classify(...)` witness
  /// can log: a file-scope `let` would be MainActor-isolated under default
  /// isolation (`STACK.md § 8`).
  private static let logger = Logger(subsystem: "com.feeder.app", category: "OpenAI")

  let name = "OpenAI"

  private let apiKey: String
  /// Internal (not private) so in-module tests can assert which model
  /// `ClassificationEngine.buildProvider` resolved.
  let model: String
  private let send: @Sendable (URLRequest) async throws -> ClassificationHTTPResponse
  private let sleep: @Sendable (Duration) async throws -> Void
  private let now: @Sendable () -> Date
  private static let requestTimeout: TimeInterval = 60
  private static let endpoint: URL = {
    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
      fatalError("Invalid OpenAI endpoint URL")
    }
    return url
  }()

  init(
    apiKey: String,
    model: String,
    send: @escaping @Sendable (URLRequest) async throws -> ClassificationHTTPResponse =
      CloudSession(requestTimeout: Self.requestTimeout).send,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.apiKey = apiKey
    self.model = model
    self.send = send
    self.sleep = sleep
    self.now = now
  }

  var isAvailable: Bool {
    get async {
      !apiKey.isEmpty
    }
  }

  var supportedLanguageCodes: Set<String>? {
    get async { nil }
  }

  func validate(categories: [CategoryDefinition]) async throws {
    guard await isAvailable else { throw OpenAIError.needsKey }
  }

  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    try await validate(categories: categories)
    let instructions = buildClassificationInstructions(from: categories)
    let truncatedBody = String(body.prefix(60_000))
    let userMessage = Self.articleMessage(title: title, body: truncatedBody)

    var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.encodeRequestBody(
      model: model, instructions: instructions, userMessage: userMessage
    )

    let response = try await CloudSession.sendWithRetry(
      request, provider: name, logger: Self.logger, send: send, sleep: sleep, now: now,
      httpFailure: { response, instant in
        Self.makeAPIError(
          statusCode: response.statusCode, retryAfter: response.retryAfter,
          body: String(data: response.data, encoding: .utf8) ?? "no body", now: instant)
      },
      transportFailure: {
        $0 is CloudSession.NonHTTPResponse ? OpenAIError.invalidResponse : OpenAIError.networkUnavailable(underlying: $0)
      })

    let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: response.data)
    guard let content = apiResponse.choices.first?.message.content else {
      throw OpenAIError.emptyResponse
    }

    let classification = try JSONDecoder().decode(OpenAIClassification.self, from: Data(content.utf8))

    return .generative(
      category: classification.category,
      confidence: classification.confidence
    )
  }

  static func articleMessage(title: String, body: String) -> String {
    "title: \(title)\ncontent: \(body)"
  }

  /// Codes and types that name one article as the cause, not the request shape
  /// or the account.
  private static let perArticleRejectionCodes: Set<String> = [
    "context_length_exceeded",
    "string_above_max_length",
    "content_policy_violation",
  ]

  /// With HTTP 429, these codes and the type `insufficient_quota` mark a
  /// billing failure. Every other HTTP 429, and a body that does not decode,
  /// stays a rate limit.
  private static let quotaFailureCodes: Set<String> = [
    "insufficient_quota",
    "credit_balance_exhausted",
    "organization_spend_limit_exceeded",
    "project_spend_limit_exceeded",
    "organization_usage_limit_exceeded",
  ]

  /// Turns a non-200 response into a failure. `retryAfter` is the raw
  /// `Retry-After` header value; `now` is the reference instant for its
  /// HTTP-date form.
  static func makeAPIError(statusCode: Int, retryAfter: String?, body: String, now: Date) -> OpenAIError {
    let failure = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: Data(body.utf8)).error
    if statusCode == 400, let failure, let rejection = perArticleRejection(failure) {
      return rejection
    }
    if statusCode == 429, let failure, let quota = quotaFailure(failure) {
      return quota
    }
    return .apiError(
      statusCode: statusCode,
      message: body,
      retryAfter: retryAfterDelay(retryAfter, now: now)
    )
  }

  private static func perArticleRejection(_ failure: OpenAIErrorEnvelope.Failure) -> OpenAIError? {
    if let code = failure.code, perArticleRejectionCodes.contains(code) {
      return .entryRejected(code: code)
    }
    if failure.type == "invalid_prompt" { return .entryRejected(code: failure.code) }
    return nil
  }

  private static func quotaFailure(_ failure: OpenAIErrorEnvelope.Failure) -> OpenAIError? {
    if let code = failure.code, quotaFailureCodes.contains(code) {
      return .quotaExhausted(code: code)
    }
    if failure.type == "insufficient_quota" { return .quotaExhausted(code: failure.code) }
    return nil
  }

  /// Omit sampling parameters: some supported models reject non-default values.
  static func encodeRequestBody(
    model: String,
    instructions: String,
    userMessage: String
  ) throws -> Data {
    let requestBody = OpenAIRequest(
      model: model,
      messages: [
        .init(role: "system", content: instructions),
        .init(role: "user", content: userMessage),
      ],
      responseFormat: .init(
        type: "json_schema",
        jsonSchema: .init(
          name: "article_classification",
          strict: true,
          schema: .classificationSchema
        )
      )
    )
    return try JSONEncoder().encode(requestBody)
  }
}

// MARK: - OpenAI API types

// All `nonisolated`: the `classify(...)` witness consumes them, and under
// default MainActor isolation these file-scope types and their synthesized
// conformances would be unusable off the main actor.

/// Internal (not private) so in-module tests can assert the
/// `ClassificationFailure` disposition mapping case by case.
nonisolated enum OpenAIError: LocalizedError {
  case needsKey
  case invalidResponse
  case apiError(statusCode: Int, message: String, retryAfter: TimeInterval?)
  case entryRejected(code: String?)
  case quotaExhausted(code: String?)
  case emptyResponse
  case networkUnavailable(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .needsKey:
      return "OpenAI API key is missing"
    case .invalidResponse:
      return "OpenAI returned an invalid response"
    case .apiError(let statusCode, let message, _):
      return "OpenAI API error \(statusCode): \(message)"
    case .entryRejected(let code):
      return "OpenAI rejected this article: \(code ?? "no code")"
    case .quotaExhausted(let code):
      return "OpenAI reported a billing failure: \(code ?? "no code")"
    case .emptyResponse:
      return "OpenAI returned an empty response"
    case .networkUnavailable(let underlying):
      return "OpenAI request failed: \(String(describing: underlying))"
    }
  }
}

/// The error envelope OpenAI returns with a non-200 status.
private nonisolated struct OpenAIErrorEnvelope: Decodable {
  struct Failure: Decodable {
    let code: String?
    let type: String?
  }

  let error: Failure
}

extension OpenAIError: ClassificationFailure {
  /// Batch-level disposition, per `ClassificationFailure`. A provider-level
  /// failure aborts the batch with a user-facing cause and leaves every entry
  /// retryable: persisting the fallback for it would misclassify the whole
  /// drain. A per-entry problem returns nil, so the drain continues and that
  /// entry takes the uncategorized fallback.
  var batchAbort: ClassificationAbortReason? {
    switch self {
    case .needsKey:
      return .needsKey
    case .apiError(let statusCode, _, _):
      switch statusCode {
      case 401:
        return .keyRejected
      case 429:
        return .rateLimited
      case 408, 500...599:
        return .providerUnavailable
      case 400...499:
        return .modelRejected
      default:
        // A status outside 400 to 599 keeps the per-entry fallback.
        return nil
      }
    case .quotaExhausted:
      return .quotaExhausted
    case .networkUnavailable:
      return .offline
    case .invalidResponse, .emptyResponse, .entryRejected:
      return nil
    }
  }

  /// The runner reads this only when `batchAbort` is non-nil, so a per-entry
  /// failure never reaches the retry state.
  var retryDisposition: ClassificationRetry {
    switch self {
    case .needsKey:
      .poll
    case .apiError(let statusCode, _, let retryAfter):
      ClassificationRetry(httpStatus: statusCode, retryAfter: retryAfter)
    case .quotaExhausted:
      .blocked
    case .networkUnavailable:
      .transient(retryAfter: nil)
    case .invalidResponse, .emptyResponse, .entryRejected:
      .poll
    }
  }
}

private nonisolated struct OpenAIRequest: Encodable {
  let model: String
  let messages: [Message]
  let responseFormat: ResponseFormat

  struct Message: Encodable {
    let role: String
    let content: String
  }

  struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: JSONSchemaWrapper

    enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }
  }

  struct JSONSchemaWrapper: Encodable {
    let name: String
    let strict: Bool
    let schema: SchemaDefinition
  }

  struct SchemaDefinition: Encodable {
    let type: String
    let properties: [String: PropertyDefinition]
    let required: [String]
    let additionalProperties: Bool

    static let classificationSchema = SchemaDefinition(
      type: "object",
      properties: [
        "category": PropertyDefinition(type: "string"),
        "confidence": PropertyDefinition(type: "number"),
      ],
      required: ["category", "confidence"],
      additionalProperties: false
    )
  }

  struct PropertyDefinition: Encodable {
    let type: String
  }

  enum CodingKeys: String, CodingKey {
    case model, messages
    case responseFormat = "response_format"
  }
}

private nonisolated struct OpenAIResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: String?
  }
}

private nonisolated struct OpenAIClassification: Decodable {
  let category: String
  let confidence: Double
}
