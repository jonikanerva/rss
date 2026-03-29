import Foundation
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "OpenAI")

/// Classifies articles using the OpenAI Chat Completions API with structured outputs.
/// Uses URLSession directly — no third-party dependencies.
nonisolated struct OpenAIClassificationProvider: ClassificationProvider {
  let name = "OpenAI"

  private let apiKey: String
  private let model = "gpt-5.4-nano"
  private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

  init(apiKey: String) {
    self.apiKey = apiKey
  }

  var isAvailable: Bool {
    get async {
      !apiKey.isEmpty
    }
  }

  func classify(
    title: String,
    body: String,
    instructions: String,
    validLabels: Set<String>
  ) async throws -> ProviderClassificationResult {
    let truncatedBody = String(body.prefix(60_000))
    let userMessage = "title: \(title)\ncontent: \(truncatedBody)"

    let requestBody = OpenAIRequest(
      model: model,
      messages: [
        .init(role: "system", content: instructions),
        .init(role: "user", content: userMessage),
      ],
      temperature: 0,
      responseFormat: .init(
        type: "json_schema",
        jsonSchema: .init(
          name: "article_classification",
          strict: true,
          schema: .classificationSchema
        )
      )
    )

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(requestBody)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw OpenAIError.invalidResponse
    }

    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      logger.error("OpenAI API error \(httpResponse.statusCode): \(body)")
      throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: body)
    }

    let apiResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
    guard let content = apiResponse.choices.first?.message.content else {
      throw OpenAIError.emptyResponse
    }

    let classification = try JSONDecoder().decode(OpenAIClassification.self, from: Data(content.utf8))

    return ProviderClassificationResult(
      categories: classification.categories,
      storyKey: classification.storyKey,
      confidence: classification.confidence
    )
  }
}

// MARK: - OpenAI API types (private)

enum OpenAIError: Error {
  case invalidResponse
  case apiError(statusCode: Int, message: String)
  case emptyResponse
}

private struct OpenAIRequest: Encodable {
  let model: String
  let messages: [Message]
  let temperature: Double
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
        "categories": PropertyDefinition(
          type: "array",
          items: PropertyDefinition.Items(type: "string")
        ),
        "storyKey": PropertyDefinition(type: "string", items: nil),
        "confidence": PropertyDefinition(type: "number", items: nil),
      ],
      required: ["categories", "storyKey", "confidence"],
      additionalProperties: false
    )
  }

  struct PropertyDefinition: Encodable {
    let type: String
    var items: Items?

    struct Items: Encodable {
      let type: String
    }

    init(type: String, items: Items? = nil) {
      self.type = type
      self.items = items
    }
  }

  enum CodingKeys: String, CodingKey {
    case model, messages, temperature
    case responseFormat = "response_format"
  }
}

private struct OpenAIResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message
  }

  struct Message: Decodable {
    let content: String?
  }
}

private struct OpenAIClassification: Decodable {
  let categories: [String]
  let storyKey: String
  let confidence: Double
}
