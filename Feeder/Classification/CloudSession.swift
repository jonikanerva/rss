import Foundation

nonisolated struct ClassificationHTTPResponse: Sendable {
  let data: Data
  let statusCode: Int
  let retryAfter: String?
}

extension ClassificationHTTPResponse {
  nonisolated init?(data: Data, response: URLResponse) {
    guard let response = response as? HTTPURLResponse else { return nil }
    // HTTP/2 lowercases field names. This lookup is case-insensitive; an
    // `allHeaderFields` subscript is not.
    self.init(data: data, statusCode: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
  }
}

/// The session for cloud requests (`STACK.md → Cloud classification`):
/// ephemeral, with no cache and no cookies. Create one per provider or client
/// instance, not one per request. Set `Authorization` on each request, never on
/// the session. `deinit` invalidates the session.
nonisolated final class CloudSession: Sendable {
  nonisolated struct NonHTTPResponse: Error {}

  private static let resourceTimeout: TimeInterval = 60
  private let session: URLSession

  var configuration: URLSessionConfiguration { session.configuration }

  init(requestTimeout: TimeInterval) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = Self.resourceTimeout
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration)
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  /// Throws the `URLSession` error unchanged, or `NonHTTPResponse` when the
  /// response is not HTTP.
  func send(_ request: URLRequest) async throws -> ClassificationHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let response = ClassificationHTTPResponse(data: data, response: response) else { throw NonHTTPResponse() }
    return response
  }
}
