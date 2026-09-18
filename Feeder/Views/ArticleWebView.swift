import SwiftUI
import WebKit

// MARK: - Static resource loading

/// Load a bundle resource as a UTF-8 string. Used by the host view to cache
/// immutable template + CSS files in static `let` bindings.
nonisolated func loadStaticResource(_ name: String, ext: String) -> String {
  guard let url = Bundle.main.url(forResource: name, withExtension: ext),
    let contents = try? String(contentsOf: url, encoding: .utf8)
  else {
    return ""
  }
  return contents
}

// MARK: - Bare-key routing

/// Where a bare keypress inside the article web view routes. `nonisolated`, so
/// the classifier below and its tests can use the `Equatable` conformance.
nonisolated enum BareKeyRoute: Equatable, Sendable {
  case j, k, r, b
}

/// Decides whether a key event is one of the app's bare-key shortcuts, with
/// shift allowed, or belongs to the web view. Any other modifier, any
/// non-matching character, and Tab, Escape and the mark-all-read chord all
/// return `nil`, so the event falls through to the superclass.
///
/// It lives in the interface layer because it speaks `NSEvent.ModifierFlags`,
/// and is `nonisolated` so the truth table is testable without AppKit plumbing.
nonisolated func bareKeyRoute(
  characters: String?,
  modifiers: NSEvent.ModifierFlags
) -> BareKeyRoute? {
  guard modifiers.intersection([.command, .option, .control]).isEmpty else {
    return nil
  }
  switch characters {
  case "j", "J": return .j
  case "k", "K": return .k
  case "r", "R": return .r
  case "b", "B": return .b
  default: return nil
  }
}

// MARK: - Bare-key forwarding web view

/// `WKWebView` subclass that routes the app's bare-key shortcuts to the same
/// actions the SwiftUI handlers use.
///
/// Once the user clicks into the article the web view is first responder, so
/// key events travel the AppKit responder chain and never reach SwiftUI. The
/// interception therefore lives in this wrapped adapter (`STACK.md § 2`). A
/// handled action consumes the event; anything else falls through, so
/// scrolling, selection and copy stay untouched. Tab, Escape and the
/// mark-all-read chord are not forwarded.
private final class BareKeyForwardingWebView: WKWebView {
  var bareKeyActions = BareKeyActions()

  override func keyDown(with event: NSEvent) {
    guard
      let route = bareKeyRoute(
        characters: event.characters, modifiers: event.modifierFlags)
    else {
      super.keyDown(with: event)
      return
    }
    let result: KeyPress.Result =
      switch route {
      case .j: bareKeyActions.onJ()
      case .k: bareKeyActions.onK()
      case .r: bareKeyActions.onR()
      case .b: bareKeyActions.onB()
      }
    if result != .handled {
      super.keyDown(with: event)
    }
  }
}

// MARK: - Article Web View

struct ArticleWebView: NSViewRepresentable {
  let entry: Entry
  /// Pre-rendered article HTML. The host computes it on a background task, so
  /// the sanitisation and template injection stay off MainActor.
  let renderedHTML: String
  /// The same actions the SwiftUI handlers dispatch, forwarded into the AppKit
  /// subclass above so the shortcuts keep working while the web view is first
  /// responder.
  @Environment(\.bareKeyActions)
  private var bareKeyActions

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // JavaScript stays disabled: the Swift-side stripping is the only defence.
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let webView = BareKeyForwardingWebView(frame: .zero, configuration: config)
    webView.bareKeyActions = bareKeyActions
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    // Refresh the forwarded actions before the reload guard below: the
    // environment rebuilds its closures even when the entry and HTML are
    // unchanged.
    (webView as? BareKeyForwardingWebView)?.bareKeyActions = bareKeyActions
    // Re-load when the entry changes or the rendered HTML changes. Hashing the
    // HTML keeps the guard cheap: comparing the strings would allocate on every
    // diff.
    let entryID = entry.feedbinEntryID
    let htmlHash = renderedHTML.hashValue
    guard
      context.coordinator.currentEntryID != entryID
        || context.coordinator.currentHTMLHash != htmlHash
    else { return }
    context.coordinator.currentEntryID = entryID
    context.coordinator.currentHTMLHash = htmlHash

    let baseURL = URL(string: entry.url)
    webView.loadHTMLString(renderedHTML, baseURL: baseURL)
  }

  // MARK: - Coordinator

  final class Coordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    var currentEntryID: Int?
    var currentHTMLHash: Int?

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      // Allow the initial HTML load and in-page fragment navigation.
      if navigationAction.navigationType == .other {
        return .allow
      }

      // Every link click opens in the system browser.
      if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
        NSWorkspace.shared.open(url)
        return .cancel
      }

      return .allow
    }
  }
}
