import Foundation
import OSLog

nonisolated enum CredentialResidue {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "CredentialResidue")

  /// GET URLs that Feeder requests only with an `Authorization` header. A cached
  /// response for any of them means the cache also holds that header.
  static let probeURLs: [URL] = [
    "https://api.feedbin.com/v2/authentication.json",
    "https://api.feedbin.com/v2/subscriptions.json",
    "https://api.feedbin.com/v2/icons.json",
    "https://api.feedbin.com/v2/unread_entries.json",
    "https://api.openai.com/v1/models",
  ].compactMap { URL(string: $0) }

  /// Removes every response from `cache` and returns true when the cache holds a
  /// response for a probe URL. Otherwise removes nothing and returns false.
  static func remove(from cache: URLCache) -> Bool {
    // Keep this check: the shared cache also holds article images, and an
    // unconditional removal makes every image load again on each call.
    guard probeURLs.contains(where: { cache.cachedResponse(for: URLRequest(url: $0)) != nil }) else {
      return false
    }
    cache.removeAllCachedResponses()
    return true
  }

  // Keep this `@concurrent`: with `SWIFT_APPROACHABLE_CONCURRENCY` on
  // (`STACK.md § 1`), a plain `nonisolated async` function runs on the caller's
  // actor, and this one does synchronous disk I/O.
  @concurrent
  static func removeFromSharedCache() async {
    guard remove(from: .shared) else { return }
    logger.notice("Removed cached responses whose requests carried credentials")
  }
}
