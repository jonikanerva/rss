import Testing
import WebKit

@testable import Feeder

// MARK: - WebKitPreheat Tests
//
// These tests cover the idempotency contract the preheat's best-effort promise
// depends on. The perf assertion itself needs a headed trace and is out of
// scope here.

@MainActor
struct WebKitPreheatTests {
  /// Every test starts here. The preheat state is global, so a test resets it
  /// and requires the cold phase with no web view, as in a fresh process.
  private func reset() throws {
    WebKitPreheat.resetForTesting()
    try #require(WebKitPreheat.phase == .cold)
    try #require(WebKitPreheat.primingWebView == nil)
  }

  @Test
  func warmIfNeededTransitionsToWarmAndRetainsPrimingWebView() throws {
    try reset()
    WebKitPreheat.warmIfNeeded()
    #expect(WebKitPreheat.phase == .warm)
    #expect(WebKitPreheat.primingWebView != nil)
  }

  /// A second `warmIfNeeded()` must be a no-op: the same hidden `WKWebView`
  /// stays, and no new one is made.
  @Test
  func warmIfNeededIsIdempotent() throws {
    try reset()
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
}
