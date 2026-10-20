import Foundation
import Testing
import WebKit

@testable import Feeder

// MARK: - Fixture transport

/// Serves every request of the fixture schemes from memory and records its
/// URL. No request reaches the network. `WKURLSchemeHandler` cannot serve
/// https, so the allowed-image fixtures use `ArticleWebPolicyFixture.scheme`
/// and add it to `img-src`. The blocked scheme has a handler too, so a request
/// that the policy fails to block is recorded, not dropped.
@MainActor
private final class RecordingSchemeHandler: NSObject, WKURLSchemeHandler {
  private(set) var requestedURLs: [URL] = []

  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else { return }
    requestedURLs.append(url)
    let isImage = url.pathExtension == "png"
    let body = isImage ? ArticleWebPolicyFixture.png : Data("<html><body>frame</body></html>".utf8)
    let response = URLResponse(
      url: url, mimeType: isImage ? "image/png" : "text/html",
      expectedContentLength: body.count, textEncodingName: nil)
    urlSchemeTask.didReceive(response)
    urlSchemeTask.didReceive(body)
    urlSchemeTask.didFinish()
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

  func paths() -> Set<String> { Set(requestedURLs.map(\.path)) }
}

/// Forwards each decision to the production coordinator and records it, so a
/// test can wait for a cancelled navigation instead of sleeping.
@MainActor
private final class RecordingNavigationDelegate: NSObject, WKNavigationDelegate {
  let coordinator: ArticleWebView.Coordinator
  private(set) var decisions: [(url: URL?, policy: WKNavigationActionPolicy)] = []
  private(set) var finishedLoads = 0

  init(coordinator: ArticleWebView.Coordinator) {
    self.coordinator = coordinator
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    let policy = await coordinator.webView(webView, decidePolicyFor: navigationAction)
    decisions.append((navigationAction.request.url, policy))
    return policy
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finishedLoads += 1
  }
}

private enum ArticleWebPolicyFixture {
  static let scheme = "feeder-fixture"
  static let blockedScheme = "feeder-blocked"
  static let baseURL = URL(string: "feeder-fixture://site.example/post")
  // A 1×1 transparent PNG.
  static let png =
    Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")
    ?? Data()
  static let testPolicy = ArticleResourcePolicy.contentSecurityPolicy(imageSources: ["https:", "\(scheme):"])
}

// MARK: - Web reader behaviour

/// Loads controlled fixtures through the production configuration and
/// coordinator, and records which requests WebKit sends.
@MainActor
@Suite(.serialized)
struct ArticleWebResourcePolicyTests {
  private struct Harness {
    let webView: WKWebView
    let handler: RecordingSchemeHandler
    let delegate: RecordingNavigationDelegate
  }

  private func makeHarness() -> Harness {
    let config = ArticleWebConfiguration.make()
    let handler = RecordingSchemeHandler()
    config.setURLSchemeHandler(handler, forURLScheme: ArticleWebPolicyFixture.scheme)
    config.setURLSchemeHandler(handler, forURLScheme: ArticleWebPolicyFixture.blockedScheme)
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    let coordinator = ArticleWebView.Coordinator()
    coordinator.webView = webView
    let delegate = RecordingNavigationDelegate(coordinator: coordinator)
    webView.navigationDelegate = delegate
    return Harness(webView: webView, handler: handler, delegate: delegate)
  }

  private func render(_ body: String, policy: String) -> String {
    renderArticleHTML(
      feedHTMLBody: body,
      title: "Fixture",
      author: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      displayDomain: "site.example",
      faviconBase64: nil,
      feedTitleInitial: Character("F"),
      scaleFactor: 1,
      template: loadStaticResource("article-template", ext: "html"),
      css: "",
      contentSecurityPolicy: policy
    )
  }

  private func loadAndFinish(_ html: String, in harness: Harness) async throws {
    harness.delegate.coordinator.load(html, baseURL: ArticleWebPolicyFixture.baseURL)
    let delegate = harness.delegate
    try await waitUntil("the fixture load finishes", timeout: .seconds(10)) {
      await MainActor.run { delegate.finishedLoads > 0 }
    }
  }

  @Test
  func templateCarriesThePolicy() {
    let template = loadStaticResource("article-template", ext: "html")
    #expect(template.contains(#"<meta http-equiv="Content-Security-Policy" content="[[csp]]">"#))
    #expect(template.contains(#"<meta name="referrer" content="no-referrer">"#))
    let html = render("<p>Body</p>", policy: ArticleResourcePolicy.contentSecurityPolicy())
    #expect(html.contains("default-src 'none'"))
    #expect(!html.contains("[[csp]]"))
  }

  @Test
  func dataStoreIsInMemoryAndRefusesCookies() async {
    let config = ArticleWebConfiguration.make()
    await ArticleWebConfiguration.applyCookiePolicy()
    #expect(config.websiteDataStore === ArticleWebConfiguration.dataStore)
    #expect(config.websiteDataStore.isPersistent == false)
    #expect(config.defaultWebpagePreferences.allowsContentJavaScript == false)
    #expect(await config.websiteDataStore.httpCookieStore.cookiePolicy == .disallow)
  }

  /// The rendered article loads its images and nothing else: the iframe becomes
  /// a link, and every other remote subresource is blocked.
  @Test
  func renderedArticleLoadsOnlyImages() async throws {
    let harness = makeHarness()
    let body = """
      <p>Text</p>
      <img src="feeder-fixture://images.example/allowed.png" alt="">
      <picture><source srcset="feeder-fixture://images.example/source.png"><img src="feeder-fixture://images.example/fallback.png" alt=""></picture>
      <img src="feeder-blocked://images.example/blocked-scheme.png" alt="">
      <iframe src="feeder-fixture://embed.example/frame.html"></iframe>
      <video src="feeder-fixture://media.example/video.mp4" poster="feeder-fixture://media.example/poster.png"></video>
      <audio src="feeder-fixture://media.example/audio.mp3"></audio>
      <object data="feeder-fixture://embed.example/object.html"></object>
      <embed src="feeder-fixture://embed.example/embed.html">
      <link rel="stylesheet" href="feeder-fixture://styles.example/sheet.css">
      <link rel="prefetch" href="feeder-fixture://styles.example/prefetch.html">
      """
    try await loadAndFinish(render(body, policy: ArticleWebPolicyFixture.testPolicy), in: harness)
    let handler = harness.handler
    try await waitUntil("the allowed images load", timeout: .seconds(10)) {
      await MainActor.run { handler.paths().contains("/allowed.png") }
    }
    let paths = handler.paths()
    #expect(paths.contains("/allowed.png"))
    #expect(paths.contains("/source.png") || paths.contains("/fallback.png"))
    let forbidden: Set<String> = [
      "/blocked-scheme.png", "/frame.html", "/video.mp4", "/audio.mp3", "/object.html",
      "/embed.html", "/sheet.css", "/prefetch.html",
    ]
    #expect(paths.isDisjoint(with: forbidden), "Sent: \(paths.intersection(forbidden))")
  }

  /// The production policy allows https images only, so an image of another
  /// scheme is never requested.
  @Test
  func productionPolicyBlocksOtherImageSchemes() async throws {
    let harness = makeHarness()
    let body = #"<img src="feeder-fixture://images.example/allowed.png" alt="">"#
    try await loadAndFinish(render(body, policy: ArticleResourcePolicy.contentSecurityPolicy()), in: harness)
    #expect(harness.handler.requestedURLs.isEmpty)
  }

  /// Raw HTML bypasses the renderer, so these frames, styles, and refreshes
  /// reach WebKit. The CSP and the navigation policy must still block them.
  @Test
  func rawFramesStylesAndRefreshAreBlocked() async throws {
    let harness = makeHarness()
    let html = """
      <!DOCTYPE html><html><head>
      <meta http-equiv="Content-Security-Policy" content="\(ArticleWebPolicyFixture.testPolicy)">
      <meta http-equiv="refresh" content="0;url=feeder-fixture://site.example/refreshed.html">
      <link rel="stylesheet" href="feeder-fixture://styles.example/raw-sheet.css">
      <style>@import url("feeder-fixture://styles.example/import.css");</style>
      </head><body>
      <img src="feeder-fixture://images.example/raw-allowed.png" alt="">
      <iframe src="feeder-fixture://embed.example/raw-frame.html"></iframe>
      </body></html>
      """
    try await loadAndFinish(html, in: harness)
    let delegate = harness.delegate
    try await waitUntil("the meta refresh is decided", timeout: .seconds(10)) {
      await MainActor.run {
        delegate.decisions.contains { $0.url?.path == "/refreshed.html" }
      }
    }
    let refresh = delegate.decisions.first { $0.url?.path == "/refreshed.html" }
    #expect(refresh?.policy == .cancel)
    let paths = harness.handler.paths()
    #expect(paths.contains("/raw-allowed.png"))
    let forbidden: Set<String> = ["/refreshed.html", "/raw-sheet.css", "/import.css", "/raw-frame.html"]
    #expect(paths.isDisjoint(with: forbidden), "Sent: \(paths.intersection(forbidden))")
    #expect(harness.webView.url == ArticleWebPolicyFixture.baseURL)
  }

  /// Loads that start before WebKit decides the previous load end on the
  /// newest article, on a new web view with a cold web content process.
  @Test
  func overlappingLoadsShowTheNewestArticle() async throws {
    let harness = makeHarness()
    let policy = ArticleResourcePolicy.contentSecurityPolicy()
    let urls = try ["a", "b", "c"].map { try #require(URL(string: "feeder-fixture://site.example/\($0)")) }
    for (index, url) in urls.enumerated() {
      harness.delegate.coordinator.load(render("<p>Article \(index)</p>", policy: policy), baseURL: url)
    }
    let delegate = harness.delegate
    let webView = harness.webView
    let newest = urls[2]
    try await waitUntil("the newest article finishes", timeout: .seconds(10)) {
      await MainActor.run { delegate.finishedLoads > 0 && webView.url == newest && !webView.isLoading }
    }
    #expect(webView.url == newest)
    let text =
      try await webView.callAsyncJavaScript(
        "return document.body.innerText", contentWorld: .defaultClient) as? String
    #expect(text?.contains("Article 2") == true)
    #expect(delegate.decisions.contains { $0.url == newest && $0.policy == .allow })
  }

  /// A second programmatic load is allowed again: the one-shot flag resets on
  /// each `load`, not once per web view.
  @Test
  func eachProgrammaticLoadIsAllowed() async throws {
    let harness = makeHarness()
    try await loadAndFinish(render("<p>One</p>", policy: ArticleResourcePolicy.contentSecurityPolicy()), in: harness)
    harness.delegate.coordinator.load(
      render("<p>Two</p>", policy: ArticleResourcePolicy.contentSecurityPolicy()),
      baseURL: ArticleWebPolicyFixture.baseURL)
    let delegate = harness.delegate
    try await waitUntil("the second load finishes", timeout: .seconds(10)) {
      await MainActor.run { delegate.finishedLoads > 1 }
    }
    #expect(delegate.decisions.allSatisfy { $0.policy == .allow })
  }
}
