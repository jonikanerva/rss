import Testing
import WebKit

@testable import Feeder

// MARK: - WebKitPreheat Tests
//
// Covers `WebKitPreheat.warmIfNeeded()` for issue #106.
//
// The actual perf assertion (first-article render time after preheat)
// requires the headed `make perf` trace and is intentionally out of scope
// here — these tests cover the idempotency contract the preheat's
// best-effort promise depends on.

@MainActor
struct WebKitPreheatTests {
  /// Hard reset before every assertion so test order can't leak state. Tests
  /// share the global `WebKitPreheat` singleton because the type IS the
  /// singleton (a MainActor-isolated enum namespace), and that mirrors how
  /// production uses it — there is only ever one app-lifetime instance.
  private func reset() {
    WebKitPreheat.resetForTesting()
  }

  @Test
  func initialPhaseIsCold() {
    reset()
    #expect(WebKitPreheat.phase == .cold)
    #expect(WebKitPreheat.primingWebView == nil)
  }

  @Test
  func warmIfNeededTransitionsToWarmAndRetainsPrimingWebView() {
    reset()
    WebKitPreheat.warmIfNeeded()
    #expect(WebKitPreheat.phase == .warm)
    #expect(WebKitPreheat.primingWebView != nil)
  }

  /// Second `warmIfNeeded()` must be a no-op — the same hidden `WKWebView`
  /// is retained and no new one is allocated. Identity comparison via
  /// `ObjectIdentifier` is the strongest form of "did we warm twice?" you
  /// can write without inspecting the underlying Web Content Process.
  @Test
  func warmIfNeededIsIdempotent() {
    reset()
    WebKitPreheat.warmIfNeeded()
    guard let firstWebView = WebKitPreheat.primingWebView else {
      Issue.record("Expected priming web view to be retained after first warm")
      return
    }
    let firstIdentity = ObjectIdentifier(firstWebView)

    WebKitPreheat.warmIfNeeded()
    guard let secondWebView = WebKitPreheat.primingWebView else {
      Issue.record("Priming web view unexpectedly cleared between idempotent warms")
      return
    }
    let secondIdentity = ObjectIdentifier(secondWebView)

    #expect(firstIdentity == secondIdentity)
    #expect(WebKitPreheat.phase == .warm)
  }

  /// Before preheat runs, nothing is retained — the article-detail render
  /// path has zero dependency on the preheat having completed; it must never
  /// be a synchronisation point on the article-click hot path.
  @Test
  func primingWebViewIsNilBeforeWarm() {
    reset()
    #expect(WebKitPreheat.primingWebView == nil)
  }

  /// After `resetForTesting()` the singleton must be indistinguishable from
  /// a fresh process. This guards against test bleed via the `static` storage
  /// that backs the singleton.
  @Test
  func resetReturnsToColdPhase() {
    reset()
    WebKitPreheat.warmIfNeeded()
    #expect(WebKitPreheat.phase == .warm)

    WebKitPreheat.resetForTesting()
    #expect(WebKitPreheat.phase == .cold)
    #expect(WebKitPreheat.primingWebView == nil)
  }
}
