import Foundation

// MARK: - Article HTML rendering

/// Pure, MainActor-free renderer for the article web view.
///
/// The regex-heavy sanitization passes and the seven template-injection
/// passes used to live on `ArticleWebView`, which is `@MainActor`. Moving
/// them into a `nonisolated` helper lets `Task.detached` run them on a
/// background cooperative thread, keeping the render path off the
/// MainActor. All inputs are plain `Sendable` values (`String`, `Date`,
/// `Character`) so the helper can be invoked from any isolation domain.
nonisolated func renderArticleHTML(
  feedHTMLBody: String,
  title: String?,
  author: String?,
  publishedAt: Date,
  displayDomain: String?,
  faviconBase64: String?,
  feedTitleInitial: Character?,
  template: String,
  css: String
) -> String {
  let dateStr = DetailDateFormatting.formatDate(publishedAt)
  let escapedTitle = (title ?? "Untitled").htmlEscaped
  let escapedAuthor = (author ?? "").htmlEscaped
  let escapedDomain = (displayDomain ?? "").lowercased().htmlEscaped
  let body = stripFeedStyles(replaceVideoIframes(feedHTMLBody))
  let favicon = renderFaviconHTML(base64: faviconBase64, fallbackInitial: feedTitleInitial)

  return
    template
    .replacingOccurrences(of: "[[style]]", with: css)
    .replacingOccurrences(of: "[[date]]", with: dateStr)
    .replacingOccurrences(of: "[[title]]", with: escapedTitle)
    .replacingOccurrences(of: "[[author]]", with: escapedAuthor)
    .replacingOccurrences(of: "[[domain]]", with: escapedDomain)
    .replacingOccurrences(of: "[[favicon]]", with: favicon)
    .replacingOccurrences(of: "[[body]]", with: body)
}

// MARK: - Favicon composition

/// Compose the favicon HTML used in the article header. Uses a base64-encoded
/// PNG when the feed has one; otherwise renders an initial-letter placeholder.
nonisolated private func renderFaviconHTML(
  base64: String?,
  fallbackInitial: Character?
) -> String {
  if let base64, !base64.isEmpty {
    return "<img class=\"favicon\" src=\"data:image/png;base64,\(base64)\" alt=\"\">"
  }
  let firstChar = fallbackInitial ?? Character("?")
  let letter = String(firstChar).htmlEscaped
  return "<div class=\"favicon-placeholder\">\(letter)</div>"
}

// MARK: - Feed style stripping

/// Patterns that strip feed CSS, scripts, and event handlers from feed HTML.
/// JS is fully disabled in the web view, so this stripping is the only defence.
/// Each pattern is applied in order via `replacingOccurrences(options: .regularExpression)`,
/// which uses `NSRegularExpression` under the hood — a value-type-safe API that
/// does not require carrying a non-`Sendable` `Regex<>` across actor boundaries.
nonisolated private let articleHTMLSanitizerPatterns: [String] = [
  "<style[^>]*>[\\s\\S]*?</style>",
  "<link[^>]*rel=[\"']stylesheet[\"'][^>]*/?>",
  "<script[^>]*>[\\s\\S]*?</script>",
  "\\s+on\\w+\\s*=\\s*\"[^\"]*\"",
  "\\s+on\\w+\\s*=\\s*'[^']*'",
  "\\s+style\\s*=\\s*\"[^\"]*\"",
  "\\s+style\\s*=\\s*'[^']*'",
]

nonisolated func stripFeedStyles(_ html: String) -> String {
  articleHTMLSanitizerPatterns.reduce(html) { result, pattern in
    result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
  }
}
