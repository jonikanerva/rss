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
    config.defaultWebpagePreferences.allowsContentJavaScript = true

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
    let js = loadResource("article-strip", ext: "js")

    let dateStr = formatDetailDate(entry.publishedAt)
    let title = escapeHTML(entry.title ?? "Untitled")
    let author = escapeHTML(entry.author ?? "")
    let domain = escapeHTML((entry.displayDomain ?? "").uppercased())
    let body = entry.bestHTML

    return template
      .replacingOccurrences(of: "[[style]]", with: css)
      .replacingOccurrences(of: "[[strip_js]]", with: js)
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
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE d. MMMM yyyy"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let dateStr = formatter.string(from: date)

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH.mm"
    let timeStr = timeFormatter.string(from: date)

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
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      // Allow initial HTML load and fragment navigations
      if navigationAction.navigationType == .other {
        decisionHandler(.allow)
        return
      }

      // Open all link clicks in the system browser
      if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }

      decisionHandler(.allow)
    }
  }
}
