import Foundation
import OSLog

/// Classifies articles using the OpenAI Chat Completions API with structured outputs.
/// Uses URLSession directly — no third-party dependencies.
nonisolated struct OpenAIClassificationProvider: ClassificationProvider {
  /// Inside the `nonisolated struct` (not file scope) so the nonisolated
  /// `classify(...)` witness can log — a file-scope `let` is MainActor-
  /// isolated under default isolation (`STACK.md § 8`, non-MainActor form).
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
    instructions: String
  ) async throws -> ProviderClassificationResult {
    let truncatedBody = String(body.prefix(60_000))
    let userMessage = "title: \(title)\nurl: \(url)\ncontent: \(truncatedBody)"

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
      throw OpenAIError.networkUnavailable(underlying: error)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpenAIError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      Self.logger.error("OpenAI API error \(httpResponse.statusCode): \(body, privacy: .private)")
      throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: body)
    }

    let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
    guard let content = apiResponse.choices.first?.message.content else {
      throw OpenAIError.emptyResponse
    }

    let classification = try JSONDecoder().decode(OpenAIClassification.self, from: Data(content.utf8))

    return ProviderClassificationResult(
      category: classification.category,
      confidence: classification.confidence
    )
  }

  /// Pure request-body seam so tests can pin the encoded wire shape —
  /// notably the ABSENCE of a "temperature" key. gpt-5.6-luna rejects any
  /// non-default temperature with a deterministic 400 ("Only the default
  /// (1) value is supported"), so the maximally compatible request across
  /// the catalog sends no sampling parameters at all and lets each model's
  /// default apply; the `json_schema` structured output still constrains
  /// the response shape.
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

// All `nonisolated`: consumed by the nonisolated `classify(...)` witness —
// under default MainActor isolation these file-scope types (and their
// synthesized Codable conformances and statics) would otherwise be
// MainActor-isolated and unusable off the main actor.

/// Internal (not private) so in-module tests can assert the
/// `ClassificationFailure` disposition mapping case by case.
nonisolated enum OpenAIError: LocalizedError {
  case invalidResponse
  case apiError(statusCode: Int, message: String)
  case emptyResponse
  case networkUnavailable(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .invalidResponse:
      return "OpenAI returned an invalid response"
    case .apiError(let statusCode, let message):
      return "OpenAI API error \(statusCode): \(message)"
    case .emptyResponse:
      return "OpenAI returned an empty response"
    case .networkUnavailable(let underlying):
      return "OpenAI request failed: \(String(describing: underlying))"
    }
  }
}

extension OpenAIError: ClassificationFailure {
  /// Batch-level disposition (see `ClassificationFailure`):
  /// - API errors (4xx incl. 401/403/404/429, and 5xx) and network failures
  ///   are deterministic or transient *provider-level* failures — persisting
  ///   Uncategorized for them would permanently misclassify the whole drain,
  ///   so they abort the batch and leave every entry retryable.
  /// - `emptyResponse` / `invalidResponse` are per-entry model-output
  ///   problems: the drain continues and the entry falls back to
  ///   Uncategorized, exactly as before.
  var abortsBatch: Bool {
    switch self {
    case .apiError(let statusCode, _):
      return statusCode >= 400
    case .networkUnavailable:
      return true
    case .invalidResponse, .emptyResponse:
      return false
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
