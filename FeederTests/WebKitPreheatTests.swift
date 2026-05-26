import Testing
import WebKit

@testable import Feeder

// MARK: - WebKitPreheat Tests
//
// Covers `WebKitPreheat.warmIfNeeded()` for issue #106.
//
// The actual perf assertion (first-article render time after preheat)
// requires the headed `make perf` trace and is intentionally out of scope
// here — these tests cover the idempotency contract and the fall-through
// behaviour the article-detail render path depends on.

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
    #expect(WebKitPreheat.warmedProcessPool == nil)
  }

  @Test
  func warmIfNeededTransitionsToWarmAndPopulatesPool() {
    reset()
    WebKitPreheat.warmIfNeeded()
    #expect(WebKitPreheat.phase == .warm)
    #expect(WebKitPreheat.warmedProcessPool != nil)
  }

  /// Second `warmIfNeeded()` must be a no-op — the same `WKProcessPool`
  /// reference is returned and no new hidden `WKWebView` is allocated.
  /// Identity comparison via `ObjectIdentifier` is the strongest form of
  /// "did we duplicate the pool?" you can write without inspecting the
  /// underlying Web Content Process.
  @Test
  func warmIfNeededIsIdempotent() {
    reset()
    WebKitPreheat.warmIfNeeded()
    guard let firstPool = WebKitPreheat.warmedProcessPool else {
      Issue.record("Expected process pool to be populated after first warm")
      return
    }
    let firstIdentity = ObjectIdentifier(firstPool)

    WebKitPreheat.warmIfNeeded()
    guard let secondPool = WebKitPreheat.warmedProcessPool else {
      Issue.record("Pool unexpectedly cleared between idempotent warms")
      return
    }
    let secondIdentity = ObjectIdentifier(secondPool)

    #expect(firstIdentity == secondIdentity)
    #expect(WebKitPreheat.phase == .warm)
  }

  /// The article-detail render path reads `warmedProcessPool` synchronously
  /// on MainActor. Before preheat runs, the read returns nil and the caller
  /// falls through to its existing inline-pool path — preheat must never be
  /// a synchronisation point on the article-click hot path.
  @Test
  func warmedProcessPoolIsNilBeforeWarm() {
    reset()
    #expect(WebKitPreheat.warmedProcessPool == nil)
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
    #expect(WebKitPreheat.warmedProcessPool == nil)
  }
}
