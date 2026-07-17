import OSLog
import WebKit

// MARK: - WebKit Preheat
//
// Issue #106 — first-article cold-start absorption.
//
// `WKWebView` lazily spins up its Web Content Process the first time a view
// is instantiated. On a fresh launch that cost lands inside the user's first
// article click — measurable as a 100-300 ms hitch versus the < 30 ms render
// budget. Preheating from the root view's `.task` modifier — which fires on
// appear, before the user can plausibly click an article — lets the
// per-article `WKWebView` reuse warm process machinery; subsequent renders
// are 5-10× faster on cold boots.
//
// Apple ships no first-party "warm up WebKit" API
// (`developer.apple.com/documentation/webkit/wkwebview` — verified for macOS
// 26 SDK), so the preheat uses one documented primitive: a hidden,
// zero-frame `WKWebView`. Loading a minimal data URL into it forces WebKit
// to spawn the Web Content Process, compile the JIT, and parse a tiny HTML
// page. This works because WebKit shares its Web Content process machinery
// globally — which is precisely why `WKProcessPool` was deprecated
// ("Creating and using multiple instances of WKProcessPool no longer has
// any effect", macOS 12.0) — so warming ANY `WKWebView` warms the machinery
// the article-detail views reuse. No pool handoff between this helper and
// `ArticleWebView` is needed or possible.
//
// All preheat orchestration lives on a `@MainActor`-isolated helper because
// the underlying `WKWebView` / `WKWebViewConfiguration` types are MainActor.
// The `.task(priority: .utility)` modifier on `ContentView` schedules the
// warm call after the root view appears — `.task` runs "before this view
// appears" per Apple's docs
// (`developer.apple.com/documentation/swiftui/view/task(name:priority:file:line:_:)`)
// and the closure body executes once the view is on screen, before the user
// can possibly click an article. `.utility` is a scheduler priority hint that
// keeps the warm call below any user-initiated work that is already running;
// it is not an idle-frame guarantee. Preheat is best-effort, never a
// synchronisation point — the article-detail render path never waits on it.

/// Lifecycle of the preheat operation. Used internally to make
/// `warmIfNeeded()` idempotent across re-entrant callers.
enum WebKitPreheatPhase: Sendable, Equatable {
  case cold
  case warming
  case warm
}

/// MainActor singleton that warms WebKit's shared Web Content process
/// machinery ahead of the user's first article click.
///
/// Implemented as a `@MainActor`-isolated `enum` namespace rather than an
/// `actor` because the orchestrated type (`WKWebView`) is already MainActor —
/// adding an `actor` indirection would force two cross-actor hops on every
/// access for zero isolation benefit. `phase` and `primingWebView` are stored
/// in `private(set)` static vars, gated by the MainActor isolation.
@MainActor
enum WebKitPreheat {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "WebKitPreheat")

  /// Current preheat lifecycle phase. Exposed read-only for tests; mutated
  /// only inside this type.
  private(set) static var phase: WebKitPreheatPhase = .cold

  /// Hidden `WKWebView` retained for the app's lifetime. Its only job is to
  /// keep the Web Content Process alive after the initial data-URL load —
  /// without a retained `WKWebView`, WebKit may tear the process down before
  /// the user's first article click and the preheat is wasted. Exposed
  /// read-only for tests; mutated only inside this type.
  private(set) static var primingWebView: WKWebView?

  /// Warm the Web Content process machinery. Idempotent — second and
  /// subsequent calls return immediately. Called from
  /// `ContentView.task(priority: .utility)` once the root view appears
  /// (before the user can interact with article rows), at `.utility`
  /// priority so the warm sits below any user-initiated work. `.task` is not
  /// an idle-frame guarantee — it runs on appear — but the preheat is
  /// best-effort and tolerant of running concurrently with rendering, so the
  /// conservative scheduling shape is sufficient to keep the launch budget
  /// in `STACK.md` § Performance budgets clean.
  ///
  /// Sequence:
  /// 1. Instantiate a zero-frame `WKWebView` with JavaScript disabled —
  ///    matches `ArticleWebView`'s config so the warm process inherits the
  ///    same content-process preferences shape.
  /// 2. Load a 32-byte data URL that forces WebKit to spin up the web
  ///    content process and parse a tiny HTML document.
  ///
  /// Best-effort: callers do not await completion before rendering articles.
  static func warmIfNeeded() {
    guard phase == .cold else { return }
    // Skip preheat in the C3 measurement test host (issue #138): it renders no
    // articles, and spinning up WKWebView in the sandboxed, long-running
    // headless host destabilises WebKit (GPU/Web-process crashes tear the host
    // down mid-measurement). Inert in production — `FEEDER_C3_MEASURE` is unset.
    guard ProcessInfo.processInfo.environment["FEEDER_C3_MEASURE"] != "1" else { return }
    phase = .warming
    logger.info("WebKit preheat starting")

    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: config)
    primingWebView = webView
    // 32 bytes of HTML — just enough to force a parse + paint cycle so the
    // Web Content Process is fully resident, not just spawned. Loading from
    // a string with a nil base URL keeps the operation entirely in-memory.
    webView.loadHTMLString("<html><body></body></html>", baseURL: nil)

    phase = .warm
    logger.info("WebKit preheat complete")
  }

  /// Test-only reset. Production code never calls this — production hits
  /// `warmIfNeeded()` exactly once per app lifetime via the root view's
  /// `.task` modifier. Exposed to the same module so unit tests can drive
  /// the idempotency assertions in `WebKitPreheatTests`.
  static func resetForTesting() {
    phase = .cold
    primingWebView = nil
  }
}
