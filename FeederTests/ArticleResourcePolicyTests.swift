import Foundation
import Synchronization
import Testing

@testable import Feeder

// MARK: - Pure policy

@Suite("Article resource policy")
struct ArticleResourcePolicyTests {
  @Test(arguments: [
    ("https://images.example/a.png", "https://images.example/a.png"),
    ("HTTPS://images.example/a.png", "HTTPS://images.example/a.png"),
    ("http://images.example/a.png?x=1", "https://images.example/a.png?x=1"),
  ])
  func imageURLAllowsHTTPSAndUpgradesHTTP(source: String, expected: String) {
    #expect(ArticleResourcePolicy.imageURL(source)?.absoluteString == expected)
  }

  @Test(arguments: [
    "/relative.png", "images/a.png", "file:///etc/hosts", "ftp://images.example/a.png",
    "data:image/png;base64,AAAA", "javascript:alert(1)", "feeder-fixture://images.example/a.png",
    "https:///no-host.png", "",
  ])
  func imageURLBlocksOtherSources(source: String) {
    #expect(ArticleResourcePolicy.imageURL(source) == nil)
  }

  @Test(arguments: [
    ("https://site.example/post", true), ("http://site.example/post", true),
    ("mailto:someone@site.example", false), ("javascript:alert(1)", false),
    ("file:///etc/hosts", false), ("zoommtg://join?id=1", false), ("feeder-fixture://x/y", false),
  ])
  func linksOpenOnlyForHTTPAndHTTPS(link: String, isAllowed: Bool) throws {
    let url = try #require(URL(string: link))
    #expect(ArticleResourcePolicy.allowsLinkOpen(url) == isAllowed)
  }

  @Test
  func productionPolicyAllowsOnlyInlineStylesAndHTTPSImages() {
    #expect(
      ArticleResourcePolicy.contentSecurityPolicy()
        == "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; base-uri 'none'; "
        + "form-action 'none'; upgrade-insecure-requests")
  }

  @Test
  func navigationAllowsOnlyThePendingLoadAndHTTPClicks() throws {
    let site = try #require(URL(string: "https://site.example/post"))
    let custom = try #require(URL(string: "zoommtg://join"))
    #expect(
      articleNavigationDecision(isUserClick: false, isMainFrame: true, url: site, isPendingProgrammaticLoad: true)
        == .allow)
    #expect(
      articleNavigationDecision(isUserClick: false, isMainFrame: true, url: site, isPendingProgrammaticLoad: false)
        == .cancel)
    #expect(
      articleNavigationDecision(isUserClick: false, isMainFrame: false, url: site, isPendingProgrammaticLoad: true)
        == .cancel)
    #expect(
      articleNavigationDecision(isUserClick: true, isMainFrame: true, url: site, isPendingProgrammaticLoad: false)
        == .openInBrowser(site))
    #expect(
      articleNavigationDecision(isUserClick: true, isMainFrame: false, url: site, isPendingProgrammaticLoad: false)
        == .openInBrowser(site))
    #expect(
      articleNavigationDecision(isUserClick: true, isMainFrame: true, url: custom, isPendingProgrammaticLoad: true)
        == .cancel)
    #expect(
      articleNavigationDecision(isUserClick: true, isMainFrame: true, url: nil, isPendingProgrammaticLoad: false)
        == .cancel)
  }

  // MARK: Renderer

  @Test
  func unknownIframeBecomesALinkAndLoadsNoFrame() {
    let html = replaceUnknownIframesWithLinks(
      #"<p>A</p><iframe src="https://embed.example/w?a=1&b=2" width="5"></iframe><p>B</p>"#)
    #expect(!html.contains("<iframe"))
    #expect(
      html.contains(
        #"<a href="https://embed.example/w?a=1&amp;b=2">Open embedded content from embed.example</a>"#))
    #expect(html.contains("<p>A</p>") && html.contains("<p>B</p>"))
  }

  @Test(arguments: [
    #"<iframe src="javascript:alert(1)"></iframe>"#,
    #"<iframe src="feeder-fixture://embed.example/frame"></iframe>"#,
    #"<iframe srcdoc="<p>x</p>"></iframe>"#,
    #"<IFRAME SRC="file:///etc/hosts"/>"#,
  ])
  func iframeWithoutHTTPSourceLeavesNothing(markup: String) {
    #expect(replaceUnknownIframesWithLinks(markup).isEmpty)
  }

  @Test
  func renderedArticleKeepsTheVideoThumbnail() {
    let html = replaceUnknownIframesWithLinks(
      replaceVideoIframes(#"<iframe src="https://www.youtube.com/embed/abc123"></iframe>"#))
    #expect(html.contains("https://i.ytimg.com/vi/abc123/hqdefault.jpg"))
    #expect(!html.contains("embed-link"))
  }

  @Test(arguments: [
    #"<meta http-equiv="refresh" content="0;url=https://tracker.example">"#,
    #"<META HTTP-EQUIV="Content-Security-Policy" content="img-src *">"#,
    #"<base href="https://other.example/">"#,
    #"<link rel="dns-prefetch" href="//tracker.example">"#,
    #"<link rel="preload" as="image" href="https://tracker.example/p.png">"#,
  ])
  func sanitizerStripsDocumentLevelTags(markup: String) {
    #expect(stripFeedStyles("<p>A</p>\(markup)<p>B</p>") == "<p>A</p><p>B</p>")
  }
}

// MARK: - Native reader image session

/// Serves every request of the image session from memory and records it. No
/// request reaches the network.
nonisolated private final class RecordingImageProtocol: URLProtocol {
  static let requests = Mutex<[URLRequest]>([])
  static let png = Data([0x89, 0x50, 0x4E, 0x47])

  static func recordedURLs() -> [String] {
    requests.withLock { $0.compactMap { $0.url?.absoluteString } }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.requests.withLock { $0.append(request) }
    guard let url = request.url, let client else { return }
    switch url.path {
    case "/redirect-to-http.png":
      redirect(to: "http://images.example/redirected.png", from: url, client: client)
    case "/redirect-to-https.png":
      redirect(to: "https://images.example/redirected.png", from: url, client: client)
    case "/missing.png":
      respond(url: url, status: 404, headers: [:], body: Data(), client: client)
    default:
      respond(url: url, status: 200, headers: ["Set-Cookie": "id=tracker; Path=/"], body: Self.png, client: client)
    }
  }

  override func stopLoading() {}

  private func respond(url: URL, status: Int, headers: [String: String], body: Data, client: any URLProtocolClient) {
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else { return }
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocol(self, didLoad: body)
    client.urlProtocolDidFinishLoading(self)
  }

  private func redirect(to target: String, from url: URL, client: any URLProtocolClient) {
    guard let targetURL = URL(string: target),
      let response = HTTPURLResponse(
        url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])
    else { return }
    client.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
    // A refused redirect ends the load with the redirect response, as the
    // HTTP loader does. A followed redirect has already replaced this load.
    client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client.urlProtocolDidFinishLoading(self)
  }
}

@Suite("Article image session", .serialized)
struct ArticleImageSessionTests {
  private func makeSession() -> ArticleImageSession {
    RecordingImageProtocol.requests.withLock { $0.removeAll() }
    return ArticleImageSession(protocolClasses: [RecordingImageProtocol.self])
  }

  @Test
  func sessionStoresNoCookiesAndNoDiskCache() throws {
    let configuration = ArticleImageSession().configuration
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.urlCredentialStorage == nil)
    let cache = try #require(configuration.urlCache)
    #expect(cache !== URLCache.shared)
    #expect(cache.diskCapacity == 0)
    #expect(configuration.identifier == nil)
  }

  @Test
  func allowedImageLoadsAndSendsNoCookie() async {
    let session = makeSession()
    let first = await session.imageData(from: "https://images.example/first.png")
    let second = await session.imageData(from: "https://images.example/second.png")
    #expect(first == RecordingImageProtocol.png)
    #expect(second == RecordingImageProtocol.png)
    let requests = RecordingImageProtocol.requests.withLock { $0 }
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == nil })
  }

  @Test
  func httpImageIsRequestedOverHTTPS() async {
    let session = makeSession()
    _ = await session.imageData(from: "http://images.example/plain.png")
    #expect(RecordingImageProtocol.recordedURLs() == ["https://images.example/plain.png"])
  }

  @Test(arguments: [
    "/relative.png", "file:///etc/hosts", "ftp://images.example/a.png", "data:image/png;base64,AAAA",
    "javascript:alert(1)",
  ])
  func blockedSourceSendsNoRequest(source: String) async {
    let session = makeSession()
    #expect(await session.imageData(from: source) == nil)
    #expect(RecordingImageProtocol.recordedURLs().isEmpty)
  }

  @Test
  func redirectToHTTPIsNotFollowed() async {
    let session = makeSession()
    #expect(await session.imageData(from: "https://images.example/redirect-to-http.png") == nil)
    #expect(RecordingImageProtocol.recordedURLs() == ["https://images.example/redirect-to-http.png"])
  }

  @Test
  func redirectToHTTPSIsFollowed() async {
    let session = makeSession()
    #expect(await session.imageData(from: "https://images.example/redirect-to-https.png") == RecordingImageProtocol.png)
    #expect(
      RecordingImageProtocol.recordedURLs() == [
        "https://images.example/redirect-to-https.png", "https://images.example/redirected.png",
      ])
  }

  @Test
  func failedResponseIsNotAnImage() async {
    let session = makeSession()
    #expect(await session.imageData(from: "https://images.example/missing.png") == nil)
  }

  @Test(arguments: ["http://images.example/a.png", "file:///a.png", "ftp://images.example/a.png"])
  func redirectGuardRefusesNonHTTPS(target: String) throws {
    let request = URLRequest(url: try #require(URL(string: target)))
    #expect(ArticleImageRedirectGuard.allows(request) == false)
  }
}
