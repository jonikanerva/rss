import Foundation
import Testing

@testable import Feeder

// MARK: - ArticleBlock round-trip + classificationText

struct ArticleBlockTests {
  @Test
  func jsonRoundtrip() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Hello world"),
      .heading(level: 2, text: "Title"),
      .codeBlock(code: "let x = 1"),
      .blockquote(text: "A wise quote"),
      .divider,
    ]
    let data = blocks.toJSONData()
    #expect(data != nil)
    let decoded = [ArticleBlock].from(data!)
    #expect(decoded?.count == 5)
  }

  @Test
  func emptyBlocksRoundtrip() {
    let blocks: [ArticleBlock] = []
    let data = blocks.toJSONData()
    #expect(data != nil)
    let decoded = [ArticleBlock].from(data!)
    #expect(decoded?.isEmpty == true)
  }

  @Test
  func classificationTextParagraph() {
    let blocks: [ArticleBlock] = [.paragraph(text: "Hello world")]
    #expect(blocks.classificationText == "Hello world")
  }

  @Test
  func classificationTextSkipsImages() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Before"),
      .image(url: "https://example.com/img.png", alt: "An image"),
      .paragraph(text: "After"),
    ]
    let text = blocks.classificationText
    #expect(text.contains("Before"))
    #expect(text.contains("After"))
    #expect(!text.contains("img.png"))
  }

  @Test
  func classificationTextSkipsDividers() {
    let blocks: [ArticleBlock] = [
      .paragraph(text: "Above"),
      .divider,
      .paragraph(text: "Below"),
    ]
    let text = blocks.classificationText
    #expect(text == "Above\nBelow")
  }

  @Test
  func classificationTextJoinsListItems() {
    let blocks: [ArticleBlock] = [
      .list(ordered: false, items: ["one", "two", "three"])
    ]
    let text = blocks.classificationText
    #expect(text.contains("one"))
    #expect(text.contains("two"))
    #expect(text.contains("three"))
  }
}

// MARK: - Entry content fallbacks

@MainActor
struct EntryContentFallbackTests {
  private func makeEntry(
    content: String? = nil,
    summary: String? = nil,
    extractedContent: String? = nil
  ) -> Entry {
    let entry = Entry(
      feedbinEntryID: 1,
      title: "Test",
      author: nil,
      url: "https://example.com/article",
      content: content,
      summary: summary,
      extractedContentURL: nil,
      publishedAt: .now,
      createdAt: .now
    )
    if let extracted = extractedContent {
      entry.extractedContent = extracted
    }
    return entry
  }

  @Test
  func feedHTMLReturnsFeedContentIgnoringExtracted() {
    let entry = makeEntry(content: "<p>feed</p>", extractedContent: "<p>extracted</p>")
    #expect(entry.feedHTML == "<p>feed</p>")
  }

  @Test
  func feedHTMLReturnsSummaryAsFallback() {
    let entry = makeEntry(summary: "A summary")
    #expect(entry.feedHTML == "A summary")
  }

  @Test
  func feedHTMLReturnsFallbackWhenAllEmpty() {
    let entry = makeEntry()
    #expect(entry.feedHTML.contains("no inline content"))
    #expect(entry.feedHTML.contains("https://example.com/article"))
  }

  @Test
  func parsedBlocksReturnsFallbackWhenEmpty() {
    let entry = makeEntry()
    let blocks = entry.parsedBlocks
    #expect(blocks.count == 1)
    if case .paragraph(let text) = blocks.first {
      #expect(text.contains("no inline content"))
      #expect(text.contains("example.com/article"))
    } else {
      Issue.record("Expected paragraph block")
    }
  }
}

// MARK: - replaceVideoIframes + extractYouTubeVideoID

struct VideoIframeTransformTests {
  @Test
  func replacesYouTubeIframe() {
    let html = """
      <iframe src="https://www.youtube.com/embed/abc123?rel=0" width="1280" height="720"></iframe>
      <p>Description</p>
      """
    let result = replaceVideoIframes(html)
    #expect(result.contains("i.ytimg.com/vi/abc123/hqdefault.jpg"))
    #expect(result.contains("youtube.com/watch?v=abc123"))
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("<iframe"))
  }

  @Test
  func leavesNonVideoIframeUnchanged() {
    let html = #"<iframe src="https://example.com/widget"></iframe>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("<iframe"))
  }

  @Test
  func returnsUnchangedWithoutIframes() {
    let html = "<p>Just text</p>"
    let result = replaceVideoIframes(html)
    #expect(result == html)
  }

  @Test
  func extractsYouTubeVideoID() {
    #expect(extractYouTubeVideoID(from: "https://www.youtube.com/embed/abc123") == "abc123")
    #expect(extractYouTubeVideoID(from: "https://youtube.com/embed/xyz?rel=0") == "xyz")
    #expect(extractYouTubeVideoID(from: "https://www.youtube-nocookie.com/embed/priv1") == "priv1")
    #expect(extractYouTubeVideoID(from: "https://vimeo.com/123") == nil)
    #expect(extractYouTubeVideoID(from: "https://www.youtube.com/watch?v=abc") == nil)
  }

  @Test
  func handlesMixedCaseIframeTag() {
    let html = #"<IFrame Src="https://www.youtube.com/embed/mix1" Width="640"></IFrame>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(result.contains("mix1"))
  }

  @Test
  func handlesIframeWithTextFallbackContent() {
    let html =
      #"<iframe src="https://www.youtube.com/embed/fb1">Your browser does not support iframes.</iframe>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("does not support"))
    #expect(!result.contains("</iframe>"))
  }

  @Test
  func handlesIframeWithHTMLFallbackContent() {
    let html =
      #"<iframe src="https://www.youtube.com/embed/fb2"><p>Please <a href="https://example.com">click here</a>.</p></iframe>"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("click here"))
    #expect(!result.contains("</iframe>"))
  }

  @Test
  func matchesSelfClosingIframe() {
    let html = #"<iframe src="https://www.youtube.com/embed/sc1" />"#
    let result = replaceVideoIframes(html)
    #expect(result.contains("video-thumbnail"))
    #expect(!result.contains("<iframe"))
  }

  @Test
  func transformThenParseProducesBlocks() {
    let html = """
      <iframe src="https://www.youtube.com/embed/test123" width="640" height="360"></iframe>
      <p>Video description</p>
      """
    let transformed = replaceVideoIframes(html)
    let blocks = parseHTMLToBlocks(transformed)
    // The transformed HTML contains <a><img>...</a> which parses as inline markdown with image
    #expect(!blocks.isEmpty)
    let allText = blocks.compactMap { block -> String? in
      guard case .paragraph(let text) = block else { return nil }
      return text
    }.joined()
    #expect(allText.contains("ytimg.com"))
  }
}
