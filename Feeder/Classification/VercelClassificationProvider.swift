import Foundation
import OSLog

nonisolated struct ClassificationHTTPResponse: Sendable {
  let data: Data
  let statusCode: Int
  let retryAfter: String?
}

nonisolated struct VercelClassificationProvider: ClassificationProvider {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "Vercel")
  let name = "Vercel AI Gateway"
  static let model = "typesafe-ai/jev"
  static let maximumRequestBytes = 24_000
  private let apiKey: String
  private let send: @Sendable (URLRequest) async throws -> ClassificationHTTPResponse
  private let now: @Sendable () -> Date

  init(
    apiKey: String,
    send: @escaping @Sendable (URLRequest) async throws -> ClassificationHTTPResponse = Self.sendRequest,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.apiKey = apiKey
    self.send = send
    self.now = now
  }

  var isAvailable: Bool { get async { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
  var supportedLanguageCodes: Set<String>? { get async { nil } }

  func validate(categories: [CategoryDefinition]) async throws {
    guard await isAvailable else { throw VercelClassificationError.needsKey }
    _ = try Self.requestBody(title: "", body: "", categories: categories)
  }

  func classify(
    title: String, body: String, url: String, categories: [CategoryDefinition]
  ) async throws -> ProviderClassificationResult {
    try await validate(categories: categories)
    try Task.checkCancellation()
    guard let endpoint = URL(string: "https://ai-gateway.vercel.sh/v1/evaluate") else {
      throw VercelClassificationError.invalidResponse
    }
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try Self.requestBody(title: title, body: body, categories: categories)
    let response: ClassificationHTTPResponse
    do {
      response = try await send(request)
    } catch {
      if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
        throw CancellationError()
      }
      if let failure = error as? VercelClassificationError { throw failure }
      Self.logger.error("Vercel AI Gateway transport failure: \(String(describing: error), privacy: .private)")
      throw VercelClassificationError.network
    }
    try Task.checkCancellation()
    guard response.statusCode == 200 else {
      let body = String(decoding: response.data, as: UTF8.self)
      Self.logger.error("Vercel AI Gateway HTTP \(response.statusCode): \(body, privacy: .private)")
      throw VercelClassificationError.http(
        response.statusCode, retryAfter: retryAfterDelay(response.retryAfter, now: now()))
    }
    return try Self.decode(response.data, categories: categories)
  }

  static func requestBody(title: String, body: String, categories: [CategoryDefinition]) throws -> Data {
    let criteria = try makeCriteria(categories)
    let question = Question(
      type: "choice",
      instructions: "Choose the single best category for this article. Choose uncategorized when no category matches.",
      criteria: criteria)
    let encoder = JSONEncoder()
    func encode(_ title: String, _ body: String) throws -> Data {
      try encoder.encode(Request(model: model, state: .init(title: title, content: body), questions: ["category": question]))
    }
    guard try encode("", "").count <= maximumRequestBytes else {
      throw VercelClassificationError.inputTooLarge
    }
    let titleCharacters = Array(title.prefix(512))
    var fittedTitle = String(titleCharacters)
    while try encode(fittedTitle, "").count > maximumRequestBytes {
      fittedTitle = String(fittedTitle.dropLast())
    }
    // The encoded byte limit includes JSON escaping and complete category metadata.
    let characters = Array(body.prefix(maximumRequestBytes))
    var low = 0
    var high = characters.count
    var best = try encode(fittedTitle, "")
    while low <= high {
      let middle = (low + high) / 2
      let candidate = try encode(fittedTitle, String(characters.prefix(middle)))
      if candidate.count <= maximumRequestBytes {
        best = candidate
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return best
  }

  static func makeCriteria(_ categories: [CategoryDefinition]) throws -> [String: String] {
    var criteria: [String: String] = [:]
    for category in categories {
      guard !category.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        criteria[category.label] == nil
      else { throw VercelClassificationError.invalidCategories }
      let keywords = category.keywords.isEmpty ? "" : "\nKeywords: " + category.keywords.joined(separator: ", ")
      criteria[category.label] = category.description + keywords
    }
    if criteria[uncategorizedLabel] == nil {
      criteria[uncategorizedLabel] = "No other category matches this article."
    }
    guard criteria.count <= 255 else { throw VercelClassificationError.invalidCategories }
    return criteria
  }

  static func decode(_ data: Data, categories: [CategoryDefinition]) throws -> ProviderClassificationResult {
    let labels = Set(try makeCriteria(categories).keys)
    guard let response = try? JSONDecoder().decode(Response.self, from: data),
      let answer = response.answers["category"],
      answer.type == "choice", labels.contains(answer.choice),
      !answer.probabilities.isEmpty, answer.probabilities[answer.choice] != nil,
      answer.probabilities.allSatisfy({ labels.contains($0.key) && $0.value.isFinite && (0...1).contains($0.value) })
    else {
      Self.logger.error("Vercel AI Gateway response rejected: \(String(decoding: data, as: UTF8.self), privacy: .private)")
      throw VercelClassificationError.invalidResponse
    }
    return .choice(category: answer.choice)
  }

  private static func sendRequest(_ request: URLRequest) async throws -> ClassificationHTTPResponse {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw VercelClassificationError.invalidResponse }
    return ClassificationHTTPResponse(
      data: data, statusCode: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
  }

  private struct Request: Encodable {
    let model: String
    let state: State
    let questions: [String: Question]
  }

  private struct State: Encodable {
    let title: String
    let content: String
  }

  private struct Question: Encodable {
    let type: String
    let instructions: String
    let criteria: [String: String]
  }

  private struct Response: Decodable {
    let answers: [String: Answer]
  }

  private struct Answer: Decodable {
    let type: String
    let choice: String
    let probabilities: [String: Double]
  }
}

nonisolated enum VercelClassificationError: Error, ClassificationFailure {
  case needsKey
  case invalidCategories
  case inputTooLarge
  case invalidResponse
  case network
  case http(Int, retryAfter: TimeInterval?)

  var batchAbort: ClassificationAbortReason? {
    switch self {
    case .needsKey: .needsKey
    case .invalidCategories: .invalidCategories
    case .inputTooLarge: .inputTooLarge
    case .invalidResponse: .invalidResponse
    case .network: .offline
    case .http(let status, _):
      switch status {
      case 401, 403: .keyRejected
      case 402, 429: .rateLimited
      case 408, 500...599: .providerUnavailable
      default: .modelRejected
      }
    }
  }

  var retryDisposition: ClassificationRetry {
    switch self {
    case .needsKey, .invalidCategories, .inputTooLarge: .poll
    case .network: .transient(retryAfter: nil)
    // An exhausted budget heals when the account is topped up, with no change
    // in the app, so it takes the backoff instead of the shared block rule.
    case .http(402, let retryAfter): .transient(retryAfter: retryAfter)
    case .http(let status, let retryAfter): ClassificationRetry(httpStatus: status, retryAfter: retryAfter)
    case .invalidResponse: .blocked
    }
  }
}
