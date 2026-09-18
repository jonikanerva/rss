import OSLog
import WebKit

// MARK: - WebKit Preheat
//
// `WKWebView` spins up its Web Content Process the first time a view is
// instantiated, and on a fresh launch that cost lands inside the user's first
// article click. WebKit shares that process machinery globally, so warming any
// `WKWebView` warms what the article-detail views reuse; no pool handoff to
// `ArticleWebView` is needed, or possible.
//
// The preheat is best-effort and never a synchronisation point: the
// article-detail render path must not wait on it.

/// Lifecycle of the preheat operation, which is what makes `warmIfNeeded()`
/// idempotent across re-entrant callers.
enum WebKitPreheatPhase: Sendable, Equatable {
  case cold
  case warming
  case warm
}

/// Warms WebKit's shared Web Content process machinery ahead of the user's
/// first article click. A `@MainActor` namespace rather than an `actor`,
/// because `WKWebView` is already MainActor and an actor would add two
/// cross-actor hops per access for no isolation benefit.
@MainActor
enum WebKitPreheat {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "WebKitPreheat")

  /// Current preheat lifecycle phase. Read-only outside this type.
  private(set) static var phase: WebKitPreheatPhase = .cold

  /// Hidden `WKWebView` retained for the app's lifetime. Without it WebKit may
  /// tear the Web Content Process down before the user's first article click,
  /// which wastes the preheat. Read-only outside this type.
  private(set) static var primingWebView: WKWebView?

  /// Warm the Web Content process machinery. Idempotent: a second call returns
  /// at once. The configuration must match `ArticleWebView`'s, so the warm
  /// process inherits the same content-process preferences. Best-effort — a
  /// caller never awaits it before rendering articles.
  static func warmIfNeeded() {
    guard phase == .cold else { return }
    // The measurement host renders no articles, and spinning up `WKWebView` in
    // that sandboxed long-running process crashes WebKit mid-run. Inert in
    // production, where the variable is unset.
    guard ProcessInfo.processInfo.environment["FEEDER_C3_MEASURE"] != "1" else { return }
    phase = .warming
    logger.info("WebKit preheat starting")

    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: config)
    primingWebView = webView
    // Just enough HTML to force a parse and paint cycle, so the Web Content
    // Process is fully resident and not merely spawned. A `nil` base URL keeps
    // the load in memory.
    webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

    phase = .warm
    logger.info("WebKit preheat complete")
  }

  /// Test-only reset. Production calls `warmIfNeeded()` once per app lifetime
  /// and never calls this.
  static func resetForTesting() {
    phase = .cold
    primingWebView = nil
  }
}
