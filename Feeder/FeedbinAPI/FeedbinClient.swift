import Foundation
import OSLog

// MARK: - Pure helpers (nonisolated, testable)

/// Create a JSONDecoder configured for Feedbin API responses.
/// Uses `convertFromSnakeCase` keys and ISO 8601 dates (with optional fractional seconds).
nonisolated func makeFeedbinDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  decoder.dateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let string = try container.decode(String.self)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) { return date }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Cannot decode date: \(string)")
  }
  return decoder
}

/// Check if a Link header indicates a next page exists.
nonisolated func hasNextPageInLinkHeader(_ headerValue: String?) -> Bool {
  guard let header = headerValue else { return false }
  return header.contains("rel=\"next\"")
}

/// Format a Date for the Feedbin API (ISO 8601 with fractional seconds).
nonisolated func formatDateForFeedbin(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

/// Map an HTTP status code to a FeedbinError, or nil if success.
nonisolated func mapHTTPStatus(_ statusCode: Int) -> FeedbinError? {
  switch statusCode {
  case 200...299: nil
  case 401: .unauthorized
  case 403: .forbidden
  case 404: .notFound
  case 429: .rateLimited
  default: .httpError(statusCode: statusCode)
  }
}

/// Feedbin API v2 client using HTTP Basic auth and async/await.
/// Reference: https://github.com/feedbin/feedbin-api
actor FeedbinClient {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "FeedbinClient")
  // swift-format-ignore: NeverForceUnwrap
  private let baseURL = URL(string: "https://api.feedbin.com/v2/")!
  private let session: URLSession
  private let credential: String  // Base64-encoded "user:password"
  private let decoder: JSONDecoder

  init(username: String, password: String) {
    guard let credentialData = "\(username):\(password)".data(using: .utf8) else {
      fatalError("Failed to encode credentials as UTF-8")
    }
    self.credential = credentialData.base64EncodedString()

    let config = URLSessionConfiguration.default
    config.httpAdditionalHeaders = [
      "Authorization": "Basic \(credentialData.base64EncodedString())"
    ]
    self.session = URLSession(configuration: config)

    self.decoder = makeFeedbinDecoder()
  }

  // MARK: - Authentication

  /// Verify credentials. Returns true if valid.
  func verifyCredentials() async throws -> Bool {
    let url = baseURL.appending(path: "authentication.json")
    let (_, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse else { return false }
    return http.statusCode == 200
  }

  // MARK: - Subscriptions

  /// Fetch all subscriptions (feeds the user is subscribed to).
  func fetchSubscriptions() async throws -> [FeedbinSubscription] {
    let url = baseURL.appending(path: "subscriptions.json")
    let (data, response) = try await session.data(from: url)
    try checkResponse(response)
    return try decoder.decode([FeedbinSubscription].self, from: data)
  }

  // MARK: - Unread Entry IDs

  /// Fetch all unread entry IDs. Returns a lightweight array of Ints.
  /// GET /v2/unread_entries.json
  func fetchUnreadEntryIDs() async throws -> [Int] {
    let url = baseURL.appending(path: "unread_entries.json")
    let (data, response) = try await session.data(from: url)
    try checkResponse(response)
    let ids = try decoder.decode([Int].self, from: data)
    FeedbinClient.logger.info("Fetched \(ids.count) unread entry IDs")
    return ids
  }

  // MARK: - Entries

  /// Fetch entries by specific IDs, in batches of 100.
  /// GET /v2/entries.json?ids=1,2,3
  func fetchEntriesByIDs(_ ids: [Int]) async throws -> [FeedbinEntry] {
    guard !ids.isEmpty else { return [] }
    var allEntries: [FeedbinEntry] = []

    let batches = stride(from: 0, to: ids.count, by: 100).map {
      Array(ids[$0..<min($0 + 100, ids.count)])
    }

    for batch in batches {
      let idString = batch.map(String.init).joined(separator: ",")
      guard var components = URLComponents(url: baseURL.appending(path: "entries.json"), resolvingAgainstBaseURL: false) else {
        throw FeedbinError.invalidResponse
      }
      components.queryItems = [URLQueryItem(name: "ids", value: idString)]
      guard let url = components.url else { throw FeedbinError.invalidResponse }

      let (data, response) = try await session.data(from: url)
      try checkResponse(response)
      let entries = try decoder.decode([FeedbinEntry].self, from: data)
      allEntries.append(contentsOf: entries)
      FeedbinClient.logger.info("Fetched batch of \(entries.count) entries by ID (\(allEntries.count) total)")
    }

    return allEntries
  }

  /// Fetch entries with optional `since` date for incremental sync.
  /// Returns entries and whether there are more pages.
  func fetchEntries(since: Date? = nil, page: Int = 1, perPage: Int = 100) async throws -> FeedbinEntriesPage {
    guard var components = URLComponents(url: baseURL.appending(path: "entries.json"), resolvingAgainstBaseURL: false) else {
      throw FeedbinError.invalidResponse
    }
    var queryItems = [
      URLQueryItem(name: "page", value: "\(page)"),
      URLQueryItem(name: "per_page", value: "\(perPage)"),
    ]
    if let since {
      queryItems.append(URLQueryItem(name: "since", value: formatDate(since)))
    }
    components.queryItems = queryItems
    guard let url = components.url else { throw FeedbinError.invalidResponse }

    let (data, response) = try await session.data(from: url)
    try checkResponse(response)
    let entries = try decoder.decode([FeedbinEntry].self, from: data)

    let hasNextPage = parseLinkHeader(response)
    let totalCount = parseRecordCount(response)

    return FeedbinEntriesPage(entries: entries, hasNextPage: hasNextPage, totalCount: totalCount)
  }

  /// Fetch all entries page by page as an async sequence.
  /// Each yielded page includes entries, pagination state, and total record count from X-Feedbin-Record-Count.
  nonisolated func fetchAllEntryPages(since: Date? = nil) -> AsyncThrowingStream<FeedbinEntriesPage, Error> {
    let client = self
    return AsyncThrowingStream { continuation in
      let task = Task {
        var page = 1
        do {
          while !Task.isCancelled {
            let result = try await client.fetchEntries(since: since, page: page)
            continuation.yield(result)
            if !result.hasNextPage || result.entries.isEmpty { break }
            page += 1
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - Icons

  /// Fetch all favicon icons for the user's subscriptions.
  /// GET /v2/icons.json
  func fetchIcons() async throws -> [FeedbinIcon] {
    let url = baseURL.appending(path: "icons.json")
    let (data, response) = try await session.data(from: url)
    try checkResponse(response)
    return try decoder.decode([FeedbinIcon].self, from: data)
  }

  // MARK: - Extracted Content

  /// Fetch extracted full content from Feedbin's Mercury Parser.
  /// The `extractedContentURL` comes from the entry's `extracted_content_url` field.
  func fetchExtractedContent(from extractedContentURL: String) async throws -> FeedbinExtractedContent? {
    guard let url = URL(string: extractedContentURL) else { return nil }
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      return nil
    }
    return try decoder.decode(FeedbinExtractedContent.self, from: data)
  }

  // MARK: - Helpers

  private func checkResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
      throw FeedbinError.invalidResponse
    }
    if let error = mapHTTPStatus(http.statusCode) {
      throw error
    }
  }

  private func parseRecordCount(_ response: URLResponse) -> Int? {
    guard
      let http = response as? HTTPURLResponse,
      let value = http.value(forHTTPHeaderField: "X-Feedbin-Record-Count"),
      let count = Int(value)
    else { return nil }
    return count
  }

  private func parseLinkHeader(_ response: URLResponse) -> Bool {
    guard let http = response as? HTTPURLResponse else { return false }
    let linkHeader =
      http.value(forHTTPHeaderField: "Links")
      ?? http.value(forHTTPHeaderField: "Link")
    return hasNextPageInLinkHeader(linkHeader)
  }

  private func formatDate(_ date: Date) -> String {
    formatDateForFeedbin(date)
  }
}

// MARK: - Errors

nonisolated enum FeedbinError: Error, LocalizedError {
  case invalidResponse
  case unauthorized
  case forbidden
  case notFound
  case rateLimited
  case httpError(statusCode: Int)

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "Invalid response from Feedbin"
    case .unauthorized: "Invalid Feedbin credentials"
    case .forbidden: "Access forbidden"
    case .notFound: "Resource not found"
    case .rateLimited: "Rate limited by Feedbin"
    case .httpError(let code): "HTTP error \(code)"
    }
  }
}
