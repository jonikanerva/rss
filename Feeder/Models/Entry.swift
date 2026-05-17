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
  /// Pre-formatted publish-time string for row display (e.g., "21.24"). Computed at persist time
  /// so the article list doesn't invoke DateFormatter per row at render time.
  var formattedPublishedTime: String = ""
  /// Pre-computed display domain (e.g., "theverge.com") — stripped of www. prefix
  var displayDomain: String?
  /// Assigned category label — denormalized for @Query predicate filtering
  var primaryCategory: String = ""
  /// Folder that contains the assigned category — denormalized for @Query folder aggregate views
  var primaryFolder: String = ""

  // MARK: - Relationships

  var feed: Feed?

  // MARK: - Classification

  /// Detected language code (e.g., "en", "fi")
  var detectedLanguage: String?

  private static let emptyContentMessage = "This article has no inline content."

  /// Feed-provided HTML for the default web view: content > summary.
  /// Always shows what the feed provides — extracted content belongs in reader view.
  var feedHTML: String {
    if let content, !content.isEmpty { return content }
    if let summary, !summary.isEmpty { return summary }
    return
      "<p class=\"empty-fallback\">\(Self.emptyContentMessage) <a href=\"\(url.htmlEscaped)\">Open in browser \u{2192}</a></p>"
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
