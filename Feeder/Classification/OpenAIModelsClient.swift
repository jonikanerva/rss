import Foundation
import OSLog

// MARK: - Wire DTO

/// One model row from `GET /v1/models`. `created` is decoded from unix
/// seconds at the wire boundary so everything past the parse works in `Date`
/// instants (`STACK.md § 10`). Extra wire fields (`object`, `owned_by`, …)
/// are tolerated by decoding only the keys named here.
nonisolated struct OpenAIModel: Sendable, Equatable {
  let id: String
  let created: Date
}

extension OpenAIModel: Decodable {
  private enum CodingKeys: String, CodingKey {
    case id
    case created
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    let unixSeconds = try container.decode(Double.self, forKey: .created)
    created = Date(timeIntervalSince1970: unixSeconds)
  }
}

/// The `{"object": "list", "data": [...]}` envelope of `GET /v1/models`.
private nonisolated struct OpenAIModelListResponse: Decodable {
  let data: [OpenAIModel]
}

// MARK: - Errors

nonisolated enum OpenAIModelsError: Error, Equatable {
  case network
  case unauthorized
  case httpStatus(Int)
  case decodingFailed
}

// MARK: - Client

/// Fetches the OpenAI model catalog for the Settings model picker. Stateless
/// — nothing about the fetched list is ever persisted; every visit to the
/// OpenAI settings section fetches fresh.
nonisolated struct OpenAIModelsClient: Sendable {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "OpenAI")

  private static let endpoint: URL = {
    guard let url = URL(string: "https://api.openai.com/v1/models") else {
      fatalError("Invalid OpenAI models endpoint URL")
    }
    return url
  }()

  func fetchModels(apiKey: String) async throws(OpenAIModelsError) -> [OpenAIModel] {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      Self.logger.error("Model list fetch failed: \(String(describing: error), privacy: .private)")
      throw .network
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw .network
    }
    guard httpResponse.statusCode == 200 else {
      let body = String(data: data, encoding: .utf8) ?? "no body"
      Self.logger.error(
        "OpenAI models API error \(httpResponse.statusCode): \(body, privacy: .private)"
      )
      if httpResponse.statusCode == 401 {
        throw .unauthorized
      }
      throw .httpStatus(httpResponse.statusCode)
    }

    return try Self.decodeModelList(data)
  }

  /// Pure decode seam so tests can drive the wire shape without a network.
  static func decodeModelList(_ data: Data) throws(OpenAIModelsError) -> [OpenAIModel] {
    do {
      return try JSONDecoder().decode(OpenAIModelListResponse.self, from: data).data
    } catch {
      throw .decodingFailed
    }
  }
}

// MARK: - Pure catalog helpers

/// Case-insensitive id-substring denylist of model families that cannot do
/// chat-completion classification. Cosmetic hygiene only: an unknown or future
/// id passes, so a new model needs no rebuild. The safety mechanism for a
/// genuinely bad pick is the `ClassificationFailure` abort path, not this list.
nonisolated let classificationModelDenylist: [String] = [
  "embedding", "whisper", "tts", "dall-e", "audio", "realtime",
  "image", "moderation", "transcribe", "search", "davinci", "babbage",
]

nonisolated func filterClassificationModels(_ models: [OpenAIModel]) -> [OpenAIModel] {
  models.filter { model in
    let id = model.id.lowercased()
    return !classificationModelDenylist.contains { id.contains($0) }
  }
}

/// Newest first, sorted on the `Date` instant — never on a formatted string
/// (`STACK.md § 10`).
nonisolated func sortModelsNewestFirst(_ models: [OpenAIModel]) -> [OpenAIModel] {
  models.sorted { $0.created > $1.created }
}
