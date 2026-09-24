import Foundation
import OSLog

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

  /// Returns the first HTTP 200 response, or throws the mapped failure when the
  /// loop sends no more requests. `httpFailure` must read `Retry-After` against
  /// the `Date` it receives. Cancellation throws `CancellationError`, also
  /// during a retry wait.
  static func sendWithRetry<Failure: ClassificationFailure>(
    _ request: URLRequest,
    provider: String,
    logger: Logger,
    send: @Sendable (URLRequest) async throws -> ClassificationHTTPResponse,
    sleep: @Sendable (Duration) async throws -> Void,
    now: @Sendable () -> Date,
    httpFailure: (ClassificationHTTPResponse, Date) -> Failure,
    transportFailure: (any Error) -> Failure
  ) async throws -> ClassificationHTTPResponse {
    var attempt = 1
    while true {
      try Task.checkCancellation()
      let failure: Failure
      let retryInput: CloudRequestFailure?
      do {
        let response = try await send(request)
        try Task.checkCancellation()
        if response.statusCode == 200 { return response }
        let instant = now()
        let retryAfter = retryAfterDelay(response.retryAfter, now: instant)
        let retryAfterText = retryAfter.map { "\($0) s" } ?? "none"
        let body = String(decoding: response.data, as: UTF8.self)
        logger.error(
          "\(provider, privacy: .public) HTTP \(response.statusCode, privacy: .public) on attempt \(attempt, privacy: .public), Retry-After \(retryAfterText, privacy: .public): \(body, privacy: .private)"
        )
        failure = httpFailure(response, instant)
        retryInput = .http(status: response.statusCode, retryAfter: retryAfter)
      } catch {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
          throw CancellationError()
        }
        if error is NonHTTPResponse { throw transportFailure(error) }
        let code = (error as? URLError)?.code
        let codeText = code.map { String($0.rawValue) } ?? "none"
        logger.error(
          "\(provider, privacy: .public) transport failure on attempt \(attempt, privacy: .public), URLError code \(codeText, privacy: .public): \(String(describing: error), privacy: .private)"
        )
        failure = transportFailure(error)
        retryInput = code.map { .transport($0) }
      }
      guard case .transient = failure.retryDisposition, let retryInput,
        let wait = CloudRequestRetry.delay(afterAttempt: attempt, failure: retryInput)
      else { throw failure }
      try await sleep(wait)
      attempt += 1
    }
  }
}
