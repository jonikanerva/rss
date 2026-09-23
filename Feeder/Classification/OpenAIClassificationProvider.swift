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
  private static let endpoint: URL = {
    guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
      fatalError("Invalid OpenAI endpoint URL")
    }
    return url
  }()

  init(apiKey: String, model: String) {
    self.apiKey = apiKey
    self.model = model
  }

  var isAvailable: Bool {
    get async {
      !apiKey.isEmpty
    }
  }

  var supportedLanguageCodes: Set<String>? {
    get async { nil }
  }

  func classify(
    title: String,
    body: String,
    url: String,
    categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    let instructions = buildClassificationInstructions(from: categories)
    let truncatedBody = String(body.prefix(60_000))
    let userMessage = Self.articleMessage(title: title, body: truncatedBody)

    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.encodeRequestBody(
      model: model, instructions: instructions, userMessage: userMessage
    )

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
      throw OpenAIError.networkUnavailable(underlying: error)
    }

    try Task.checkCancellation()
    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpenAIError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      Self.logger.error("OpenAI API error \(httpResponse.statusCode): \(body, privacy: .private)")
      throw Self.makeAPIError(response: httpResponse, body: body, now: Date())
    }

    let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
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

  /// Turns a non-200 response into a failure. `now` is a parameter, so the
  /// HTTP-date form of `Retry-After` is testable.
  static func makeAPIError(response: HTTPURLResponse, body: String, now: Date) -> OpenAIError {
    if response.statusCode == 400, let rejection = perArticleRejection(body: body) {
      return rejection
    }
    // HTTP/2 lowercases field names. This lookup is case-insensitive; an
    // `allHeaderFields` subscript is not.
    let header = response.value(forHTTPHeaderField: "Retry-After")
    return .apiError(
      statusCode: response.statusCode,
      message: body,
      retryAfter: retryAfterDelay(header, now: now)
    )
  }

  private static func perArticleRejection(body: String) -> OpenAIError? {
    guard let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: Data(body.utf8))
    else { return nil }
    if let code = envelope.error.code, perArticleRejectionCodes.contains(code) {
      return .entryRejected(code: code)
    }
    if envelope.error.type == "invalid_prompt" { return .entryRejected(code: envelope.error.code) }
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
  case invalidResponse
  case apiError(statusCode: Int, message: String, retryAfter: TimeInterval?)
  case entryRejected(code: String?)
  case emptyResponse
  case networkUnavailable(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "OpenAI returned an invalid response"
    case .apiError(let statusCode, let message, _):
      return "OpenAI API error \(statusCode): \(message)"
    case .entryRejected(let code):
      return "OpenAI rejected this article: \(code ?? "no code")"
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
    case .apiError(let statusCode, _, let retryAfter):
      ClassificationRetry(httpStatus: statusCode, retryAfter: retryAfter)
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
