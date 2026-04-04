import Foundation
import SwiftData

@Model
final class Entry {
  /// Feedbin entry ID — used for deduplication
  @Attribute(.unique)
  var feedbinEntryID: Int
  /// Title (may be nil from Feedbin)
  var title: String?
  /// Author (may be nil from Feedbin)
  var author: String?
  /// Entry URL
  var url: String
  /// Feed-provided content (HTML)
  var content: String?
  /// Summary text
  var summary: String?
  /// Full extracted content from Feedbin's Mercury Parser (HTML)
  var extractedContent: String?
  /// URL to fetch extracted content from Feedbin
  var extractedContentURL: String?
  /// Published date (from feed, converted to UTC by Feedbin)
  var publishedAt: Date
  /// Created date in Feedbin (used for incremental sync)
  var createdAt: Date
  /// Whether this entry has been read
  var isRead: Bool = false
  /// Whether this entry has been classified (controls UI visibility)
  var isClassified: Bool = false
  /// Pre-stripped plain text body (computed once at persist/extract time, used by classification)
  var plainText: String = ""
  /// Pre-stripped summary plain text (computed at persist time, used by row view)
  var summaryPlainText: String = ""
  /// JSON-encoded [ArticleBlock] for rich article rendering (computed at persist time)
  var articleBlocksData: Data?
  /// Pre-formatted date string for display (e.g., "Today, 5th Mar, 21:24")
  var formattedDate: String = ""
  /// Pre-computed display domain (e.g., "theverge.com") — stripped of www. prefix
  var displayDomain: String?
  /// Assigned category label — denormalized for @Query predicate filtering
  var primaryCategory: String = ""
  /// Folder that contains the assigned category — denormalized for @Query folder aggregate views
  var primaryFolder: String = ""

  // MARK: - Relationships

  var feed: Feed?

  // MARK: - Classification

  /// Generated story key for grouping
  var storyKey: String?
  /// Detected language code (e.g., "en", "fi")
  var detectedLanguage: String?

  /// Cached decoded blocks — transient, not persisted. Decoded once on first access.
  @Transient
  private var _cachedBlocks: [ArticleBlock]?

  /// Clear the transient block cache so the next `parsedBlocks` access re-decodes from `articleBlocksData`.
  func invalidateBlocksCache() {
    _cachedBlocks = nil
  }

  /// Decoded article blocks for display. Falls back to plain text paragraph.
  /// Returns a fallback "Open in browser" link when content is empty or a Feedbin placeholder.
  /// Cached after first decode to avoid JSON parsing on every re-render.
  var parsedBlocks: [ArticleBlock] {
    if let cached = _cachedBlocks { return cached }
    let blocks: [ArticleBlock]
    if let data = articleBlocksData, let decoded = [ArticleBlock].from(data), !decoded.isEmpty {
      let text = decoded.classificationText
      if Self.isFeedbinPlaceholder(text) {
        blocks = emptyContentFallbackBlocks
      } else {
        blocks = decoded
      }
    } else if !plainText.isEmpty, !Self.isFeedbinPlaceholder(plainText) {
      blocks = [.paragraph(text: plainText)]
    } else {
      blocks = emptyContentFallbackBlocks
    }
    _cachedBlocks = blocks
    return blocks
  }

  private var emptyContentFallbackBlocks: [ArticleBlock] {
    [.paragraph(text: "This article has no inline content. [Open in browser \u{2192}](\(url))")]
  }

  /// Best available HTML body: extracted > content > summary.
  /// Returns a fallback "Open in browser" link when no real content is available
  /// or when the content is a known Feedbin placeholder (e.g. stripped iframes).
  var bestHTML: String {
    let candidate =
      [extractedContent, content, summary]
      .compactMap { $0 }
      .first(where: { !$0.isEmpty }) ?? ""
    if candidate.isEmpty || Self.isFeedbinPlaceholder(candidate) {
      return emptyContentFallbackHTML
    }
    return candidate
  }

  private var emptyContentFallbackHTML: String {
    "<p class=\"empty-fallback\">This article has no inline content. <a href=\"\(url.htmlEscaped)\">Open in browser \u{2192}</a></p>"
  }

  private static func isFeedbinPlaceholder(_ html: String) -> Bool {
    html.localizedCaseInsensitiveContains("if you trust this content")
  }

  init(
    feedbinEntryID: Int,
    title: String?,
    author: String?,
    url: String,
    content: String?,
    summary: String?,
    extractedContentURL: String?,
    publishedAt: Date,
    createdAt: Date
  ) {
    self.feedbinEntryID = feedbinEntryID
    self.title = title
    self.author = author
    self.url = url
    self.content = content
    self.summary = summary
    self.extractedContentURL = extractedContentURL
    self.publishedAt = publishedAt
    self.createdAt = createdAt
  }
}
