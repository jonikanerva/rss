import Foundation
import Testing

@testable import Feeder

// MARK: - renderArticleHTML

/// Tests for the pure article HTML renderer. The helper is intentionally
/// `nonisolated` so it can run inside a `Task.detached` from the article
/// detail view without touching MainActor. These tests exercise the
/// sanitization passes, template-injection passes, and favicon composition
/// in isolation from the web view.
struct ArticleHTMLRendererTests {
  private static let template = """
    <html style="--app-scale: [[scale]]"><head>[[style]]</head><body>\
    <div class="meta">[[date]] [[domain]] [[author]] [[favicon]]</div>\
    <h1>[[title]]</h1>[[body]]</body></html>
    """
  private static let css = "body { color: red; }"
  private static let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private static func render(
    body: String,
    title: String? = "Title",
    author: String? = "Author",
    domain: String? = "example.com",
    faviconBase64: String? = nil,
    feedTitleInitial: Character? = Character("E"),
    scaleFactor: CGFloat = 1.0
  ) -> String {
    renderArticleHTML(
      feedHTMLBody: body,
      title: title,
      author: author,
      publishedAt: publishedAt,
      displayDomain: domain,
      faviconBase64: faviconBase64,
      feedTitleInitial: feedTitleInitial,
      scaleFactor: scaleFactor,
      template: template,
      css: css
    )
  }

  @Test
  func emptyBodyProducesTemplateWithoutBodyMarker() {
    let html = Self.render(body: "")
    #expect(!html.contains("[[body]]"))
    #expect(html.contains("<h1>Title</h1>"))
  }

  @Test
  func scriptTagIsStripped() {
    let html = Self.render(body: "<p>Safe</p><script>alert('x')</script><p>End</p>")
    #expect(!html.contains("<script"))
    #expect(!html.contains("alert"))
    #expect(html.contains("<p>Safe</p>"))
    #expect(html.contains("<p>End</p>"))
  }

  @Test
  func inlineStyleAttributeIsStripped() {
    let html = Self.render(body: "<p style=\"color:red\">Hello</p>")
    #expect(!html.contains("style=\"color:red\""))
    #expect(html.contains("<p>Hello</p>"))
  }

  @Test
  func styleBlockIsStripped() {
    let html = Self.render(body: "<style>.foo { color: blue; }</style><p>Body</p>")
    #expect(!html.contains("<style"))
    #expect(!html.contains("color: blue"))
    #expect(html.contains("<p>Body</p>"))
  }

  @Test
  func stylesheetLinkIsStripped() {
    let html = Self.render(body: "<link rel=\"stylesheet\" href=\"foo.css\"><p>Body</p>")
    #expect(!html.contains("<link"))
    #expect(html.contains("<p>Body</p>"))
  }

  @Test
  func eventHandlerAttributesAreStripped() {
    let html = Self.render(body: "<a href=\"#\" onclick=\"evil()\">Link</a>")
    #expect(!html.contains("onclick"))
    #expect(!html.contains("evil()"))
    #expect(html.contains("<a href=\"#\">Link</a>"))
  }

  @Test
  func youTubeIframeIsReplacedWithThumbnail() {
    let html = Self.render(
      body: "<iframe src=\"https://www.youtube.com/embed/dQw4w9WgXcQ\"></iframe>"
    )
    #expect(!html.contains("<iframe"))
    #expect(html.contains("class=\"video-thumbnail\""))
    #expect(html.contains("dQw4w9WgXcQ/hqdefault.jpg"))
    #expect(html.contains("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
  }

  @Test
  func missingFaviconUsesPlaceholderLetter() {
    let html = Self.render(
      body: "<p>Body</p>",
      faviconBase64: nil,
      feedTitleInitial: Character("V")
    )
    #expect(html.contains("favicon-placeholder"))
    #expect(html.contains(">V<"))
    #expect(!html.contains("<img class=\"favicon\""))
  }

  @Test
  func faviconBase64ProducesImgTag() {
    let html = Self.render(
      body: "<p>Body</p>",
      faviconBase64: "ABCDEF",
      feedTitleInitial: Character("V")
    )
    #expect(html.contains("<img class=\"favicon\" src=\"data:image/png;base64,ABCDEF\""))
    #expect(!html.contains("favicon-placeholder"))
  }

  @Test
  func missingFeedInitialFallsBackToQuestionMark() {
    let html = Self.render(
      body: "<p>Body</p>",
      faviconBase64: nil,
      feedTitleInitial: nil
    )
    #expect(html.contains("favicon-placeholder"))
    #expect(html.contains(">?<"))
  }

  @Test
  func nilTitleRendersAsUntitled() {
    let html = Self.render(body: "<p>Body</p>", title: nil)
    #expect(html.contains("<h1>Untitled</h1>"))
  }

  @Test
  func titleIsHTMLEscaped() {
    let html = Self.render(body: "", title: "Tom & Jerry <3>")
    #expect(html.contains("Tom &amp; Jerry &lt;3&gt;"))
    #expect(!html.contains("<h1>Tom & Jerry <3></h1>"))
  }

  @Test
  func domainIsLowercased() {
    let html = Self.render(body: "", domain: "Example.COM")
    #expect(html.contains("example.com"))
    #expect(!html.contains("Example.COM"))
  }

  @Test
  func cssIsInjectedIntoStylePlaceholder() {
    let html = Self.render(body: "")
    #expect(html.contains("body { color: red; }"))
    #expect(!html.contains("[[style]]"))
  }

  @Test
  func scaleFactorIsInjectedAsCustomProperty() {
    let html = Self.render(body: "", scaleFactor: 1.15)
    #expect(html.contains("--app-scale: 1.1500"))
    #expect(!html.contains("[[scale]]"))
  }

  @Test
  func scaleFactorOneRendersOne() {
    let html = Self.render(body: "", scaleFactor: 1.0)
    #expect(html.contains("--app-scale: 1.0000"))
  }
}
