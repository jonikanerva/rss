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

/// Where a bare keypress inside the article web view should route.
/// `nonisolated` so the synthesized `Equatable` conformance is usable from
/// nonisolated contexts (the classifier below and its unit tests).
nonisolated enum BareKeyRoute: Equatable, Sendable {
  case j, k, r, b
}

/// Pure classifier behind `BareKeyForwardingWebView.keyDown(with:)`: decides
/// whether a key event is one of the app's bare-key shortcuts (j/k/r/b —
/// shift allowed, so the uppercase forms route too) or belongs to the web
/// view (scrolling, selection, copy). Anything with command/option/control,
/// any non-matching character, and Tab/Escape/⇧A all return `nil` so the
/// event falls through to `super.keyDown(with:)`.
///
/// Lives in the interface layer (not `Helpers/`) because it speaks
/// `NSEvent.ModifierFlags`; `nonisolated` so the truth table is unit-testable
/// without AppKit event plumbing.
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

/// `WKWebView` subclass that routes the app's bare-key shortcuts (J/K/R/B)
/// to the same `BareKeyActions` the SwiftUI `onKeyPress` handlers use.
///
/// Why AppKit: once the user clicks into the article, the web view is first
/// responder and key events travel the AppKit responder chain — they never
/// reach SwiftUI's `onKeyPress` handlers, and SwiftUI has no API to
/// intercept keys held by an NSView first responder. The interception
/// therefore lives in this already-existing NSViewRepresentable adapter
/// (STACK.md §2: AppKit only as a wrapped adapter). A `.handled` action
/// consumes the event; `.ignored` or no match falls through to
/// `super.keyDown(with:)` so space/arrow/Page scrolling, text selection,
/// and ⌘C stay untouched. Tab, Escape, and ⇧A are deliberately not
/// forwarded.
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
  /// Pre-rendered article HTML. The host view computes this on a background
  /// task via `renderArticleHTML(...)` and passes the result in. This keeps
  /// regex sanitization and template injection off the MainActor.
  let renderedHTML: String
  /// Same actions the SwiftUI `BareKeyHandler` modifiers dispatch — injected
  /// at the split-view root, forwarded into the AppKit subclass above so
  /// R/B (and J/K) keep working while the web view is first responder.
  @Environment(\.bareKeyActions)
  private var bareKeyActions

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // JS fully disabled — all stripping done in Swift before injection
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let webView = BareKeyForwardingWebView(frame: .zero, configuration: config)
    webView.bareKeyActions = bareKeyActions
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    // Refresh the forwarded actions on every update, BEFORE the reload
    // guard below — the environment's closures are rebuilt by ContentView
    // re-evaluations even when the entry and HTML are unchanged.
    (webView as? BareKeyForwardingWebView)?.bareKeyActions = bareKeyActions
    // Re-load when either the entry changes (selection) or the rendered HTML
    // changes (text-size picker — same entry, new `--app-scale`). Hashing the
    // HTML keeps the guard cheap and avoids the `String` heap allocation a
    // direct `currentHTML != renderedHTML` would incur on every diff.
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
      // Allow initial HTML load and fragment navigations
      if navigationAction.navigationType == .other {
        return .allow
      }

      // Open all link clicks in the system browser
      if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
        NSWorkspace.shared.open(url)
        return .cancel
      }

      return .allow
    }
  }
}
