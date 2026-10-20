import Foundation
import OSLog

// MARK: - Article image session

/// Loads article images for the native reader under `ArticleResourcePolicy`
/// (`STACK.md § 8`): an ephemeral session with no cookies, no credentials, and
/// a memory-only cache. A redirect must stay on https.
nonisolated final class ArticleImageSession: Sendable {
  /// One session for the reader, so image requests share open connections.
  static let reader = ArticleImageSession()

  private static let logger = Logger(subsystem: "com.feeder.app", category: "ArticleImageSession")
  private static let memoryCacheBytes = 32 * 1024 * 1024
  private let session: URLSession

  var configuration: URLSessionConfiguration { session.configuration }

  /// `protocolClasses` lets a test serve every request from memory.
  init(protocolClasses: [AnyClass] = []) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.urlCache = URLCache(memoryCapacity: Self.memoryCacheBytes, diskCapacity: 0)
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 60
    configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
    session = URLSession(configuration: configuration)
  }

  deinit {
    session.finishTasksAndInvalidate()
  }

  /// The image data, or `nil` when the policy blocks the source or the load
  /// fails. A blocked source sends no request.
  func imageData(from source: String) async -> Data? {
    guard let url = ArticleResourcePolicy.imageURL(source) else { return nil }
    do {
      let (data, response) = try await session.data(for: URLRequest(url: url), delegate: ArticleImageRedirectGuard())
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty
      else {
        Self.logger.debug("Article image not loaded: \(url.absoluteString, privacy: .private)")
        return nil
      }
      return data
    } catch {
      Self.logger.debug(
        "Article image failed: \(url.absoluteString, privacy: .private): \(String(describing: error), privacy: .private)"
      )
      return nil
    }
  }
}

/// Refuses a redirect to a URL that `ArticleResourcePolicy` does not allow. The
/// load then ends with the redirect response, which is not a success.
nonisolated final class ArticleImageRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  // The completion-handler requirement: the `async` form of this requirement
  // crashes the Swift 6.4 compiler in its Objective-C thunk.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(Self.allows(request) ? request : nil)
  }

  static func allows(_ request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased() else { return false }
    return ArticleResourcePolicy.imageSchemes.contains(scheme)
  }
}
