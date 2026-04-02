import SwiftUI
import WebKit

// MARK: - Cached DateFormatters

private let webViewDateFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "EEEE d. MMMM yyyy"
  f.locale = Locale(identifier: "en_US_POSIX")
  return f
}()

private let webViewTimeFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateFormat = "HH.mm"
  return f
}()

// MARK: - Article Web View

struct ArticleWebView: NSViewRepresentable {
  let entry: Entry

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    // Disable JavaScript from feed content for security.
    // Our strip script is injected as a WKUserScript instead.
    config.defaultWebpagePreferences.allowsContentJavaScript = false

    let stripJS = loadResource("article-strip", ext: "js")
    if !stripJS.isEmpty {
      let script = WKUserScript(
        source: stripJS,
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
      )
      config.userContentController.addUserScript(script)
    }

    let webView = WKWebView(frame: .zero, configuration: config)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")
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

    let dateStr = formatDetailDate(entry.publishedAt)
    let title = escapeHTML(entry.title ?? "Untitled")
    let author = escapeHTML(entry.author ?? "")
    let domain = escapeHTML((entry.displayDomain ?? "").uppercased())
    let body = entry.bestHTML

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

  private func formatDetailDate(_ date: Date) -> String {
    let dateStr = webViewDateFormatter.string(from: date)
    let timeStr = webViewTimeFormatter.string(from: date)
    return "\(dateStr) AT \(timeStr)".uppercased()
  }

  private func escapeHTML(_ string: String) -> String {
    string
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
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
