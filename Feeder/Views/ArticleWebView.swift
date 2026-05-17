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

// MARK: - Article Web View

struct ArticleWebView: NSViewRepresentable {
  let entry: Entry
  /// Pre-rendered article HTML. The host view computes this on a background
  /// task via `renderArticleHTML(...)` and passes the result in. This keeps
  /// regex sanitization and template injection off the MainActor.
  let renderedHTML: String

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // JS fully disabled — all stripping done in Swift before injection
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    context.coordinator.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
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
