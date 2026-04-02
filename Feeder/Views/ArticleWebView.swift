import SwiftUI
import WebKit

// MARK: - Article Web View

struct ArticleWebView: NSViewRepresentable {
  let entry: Entry

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // JS fully disabled — all stripping done in Swift before injection
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.underPageBackgroundColor = .clear
    context.coordinator.webView = webView
    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    let entryID = entry.feedbinEntryID
    guard context.coordinator.currentEntryID != entryID else { return }
    context.coordinator.currentEntryID = entryID

    let html = buildHTML(for: entry)
    let baseURL = URL(string: entry.url)
    webView.loadHTMLString(html, baseURL: baseURL)
  }

  private func buildHTML(for entry: Entry) -> String {
    let template = loadResource("article-template", ext: "html")
    let css = loadResource("article-style", ext: "css")

    let dateStr = DetailDateFormatting.formatDate(entry.publishedAt)
    let title = escapeHTML(entry.title ?? "Untitled")
    let author = escapeHTML(entry.author ?? "")
    let domain = escapeHTML((entry.displayDomain ?? "").lowercased())
    let body = stripFeedStyles(entry.bestHTML)

    return
      template
      .replacingOccurrences(of: "[[style]]", with: css)
      .replacingOccurrences(of: "[[date]]", with: dateStr)
      .replacingOccurrences(of: "[[title]]", with: title)
      .replacingOccurrences(of: "[[author]]", with: author)
      .replacingOccurrences(of: "[[domain]]", with: domain)
      .replacingOccurrences(of: "[[body]]", with: body)
  }

  private func loadResource(_ name: String, ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
      let contents = try? String(contentsOf: url, encoding: .utf8)
    else {
      return ""
    }
    return contents
  }

  private func escapeHTML(_ string: String) -> String {
    string
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Strip feed CSS, scripts, and event handlers from HTML content in Swift.
  /// This replaces the JS-based stripping, ensuring it works even with JS disabled.
  private func stripFeedStyles(_ html: String) -> String {
    var result = html

    // Remove <style> tags and their content
    result = result.replacingOccurrences(
      of: "<style[^>]*>[\\s\\S]*?</style>",
      with: "",
      options: .regularExpression
    )

    // Remove <link rel="stylesheet"> tags
    result = result.replacingOccurrences(
      of: "<link[^>]*rel=[\"']stylesheet[\"'][^>]*/?>",
      with: "",
      options: .regularExpression
    )

    // Remove <script> tags and their content
    result = result.replacingOccurrences(
      of: "<script[^>]*>[\\s\\S]*?</script>",
      with: "",
      options: .regularExpression
    )

    // Remove event handler attributes (onclick, onerror, onload, etc.)
    result = result.replacingOccurrences(
      of: "\\s+on\\w+\\s*=\\s*\"[^\"]*\"",
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: "\\s+on\\w+\\s*=\\s*'[^']*'",
      with: "",
      options: .regularExpression
    )

    // Strip inline style attributes entirely
    // This is aggressive but matches our goal: only our CSS should apply
    result = result.replacingOccurrences(
      of: "\\s+style\\s*=\\s*\"[^\"]*\"",
      with: "",
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: "\\s+style\\s*=\\s*'[^']*'",
      with: "",
      options: .regularExpression
    )

    return result
  }

  // MARK: - Coordinator

  final class Coordinator: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    var currentEntryID: Int?

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
