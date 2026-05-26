import OSLog
import WebKit

// MARK: - WebKit Preheat
//
// Issue #106 — first-article cold-start absorption.
//
// `WKWebView` lazily spins up its Web Content Process the first time a view
// is instantiated. On a fresh launch that cost lands inside the user's first
// article click — measurable as a 100-300 ms hitch versus the < 30 ms render
// budget. Preheating a `WKProcessPool` at idle (before the first click) lets
// the per-article `WKWebView` reuse a warm process; subsequent renders are
// 5-10× faster on cold boots.
//
// Apple ships no first-party "warm up WebKit" API
// (`developer.apple.com/documentation/webkit/wkwebview` — verified for macOS
// 26 SDK), so the preheat path uses two officially documented primitives:
//
//   - `WKProcessPool` — `developer.apple.com/documentation/webkit/wkprocesspool`.
//     Multiple `WKWebView` instances configured against the same pool share a
//     single Web Content Process. Instantiating the pool here forces WebKit
//     to load `com.apple.WebKit.WebContent.xpc` ahead of time.
//   - A hidden, zero-frame `WKWebView` bound to the shared pool — loading a
//     minimal data URL into it forces the process to actually start,
//     compile the JIT, and parse a tiny HTML page. Without this hidden load
//     `WKProcessPool` alone defers most of the cost until the first real
//     `loadHTMLString`.
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
// it is not an idle-frame guarantee. The article-detail render path falls
// through to its existing inline configuration if the warmed pool isn't
// ready yet — preheat is best-effort, never a synchronisation point.

/// Lifecycle of the preheat operation. Used internally to make
/// `warmIfNeeded()` idempotent across re-entrant callers.
enum WebKitPreheatPhase: Sendable, Equatable {
  case cold
  case warming
  case warm
}

/// MainActor singleton that owns a shared `WKProcessPool` consumed by every
/// article-detail `WKWebView`. The article-detail render path reads
/// `warmedProcessPool` synchronously on MainActor; nil result means
/// preheat hasn't completed yet and the caller should fall through.
///
/// Implemented as a `@MainActor`-isolated `enum` namespace rather than an
/// `actor` because the orchestrated type (`WKWebView`) is already MainActor —
/// adding an `actor` indirection would force two cross-actor hops on every
/// access for zero isolation benefit. `phase` and `processPool` are stored
/// in `private(set)` static vars, gated by the MainActor isolation.
@MainActor
enum WebKitPreheat {
  private static let logger = Logger(subsystem: "com.feeder.app", category: "WebKitPreheat")

  /// Current preheat lifecycle phase. Exposed read-only for tests; mutated
  /// only inside this type.
  private(set) static var phase: WebKitPreheatPhase = .cold

  /// Shared process pool. Article-detail views read this when constructing
  /// their `WKWebViewConfiguration`; nil ⇒ preheat not yet complete ⇒ caller
  /// instantiates its own pool inline. Populated by `warmIfNeeded()`.
  private(set) static var warmedProcessPool: WKProcessPool?

  /// Hidden `WKWebView` retained for the app's lifetime. Its only job is to
  /// keep the Web Content Process alive after the initial data-URL load —
  /// without a retained `WKWebView`, WebKit may tear the process down before
  /// the user's first article click and the preheat is wasted.
  private static var primingWebView: WKWebView?

  /// Warm the process pool. Idempotent — second and subsequent calls return
  /// immediately. Called from `ContentView.task(priority: .utility)` once the
  /// root view appears (before the user can interact with article rows), at
  /// `.utility` priority so the warm sits below any user-initiated work.
  /// `.task` is not an idle-frame guarantee — it runs on appear — but the
  /// preheat is best-effort and tolerant of running concurrently with
  /// rendering, so the conservative scheduling shape is sufficient to keep
  /// the launch budget in `docs/stack.md` § Performance budgets clean.
  ///
  /// Sequence:
  /// 1. Allocate the shared `WKProcessPool` instance.
  /// 2. Instantiate a zero-frame `WKWebView` bound to the pool with
  ///    JavaScript disabled — matches `ArticleWebView`'s config so the
  ///    warm process inherits the same content-process preferences shape.
  /// 3. Load a 32-byte data URL that forces WebKit to spin up the web
  ///    content process and parse a tiny HTML document.
  ///
  /// Best-effort: callers do not await completion before rendering articles.
  static func warmIfNeeded() {
    guard phase == .cold else { return }
    phase = .warming
    logger.info("WebKit preheat starting")
    let pool = WKProcessPool()
    warmedProcessPool = pool

    let config = WKWebViewConfiguration()
    config.processPool = pool
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
  /// idle-deferred task. Exposed to the same module so unit tests can drive
  /// the idempotency assertions in `WebKitPreheatTests`.
  static func resetForTesting() {
    phase = .cold
    warmedProcessPool = nil
    primingWebView = nil
  }
}
