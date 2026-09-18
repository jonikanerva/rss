import Foundation

// MARK: - Article HTML rendering

/// Pure, MainActor-free renderer for the article web view. Every input is a
/// plain `Sendable` value, so a detached task can run the regex sanitisation
/// and the template injection off MainActor.
///
/// `scaleFactor` is the same multiplier `AppFontSettings` applies to its font
/// aliases. Injecting it as a CSS custom property keeps the reader pane in
/// lockstep with the SwiftUI surfaces.
nonisolated func renderArticleHTML(
  feedHTMLBody: String,
  title: String?,
  author: String?,
  publishedAt: Date,
  displayDomain: String?,
  faviconBase64: String?,
  feedTitleInitial: Character?,
  scaleFactor: CGFloat,
  template: String,
  css: String
) -> String {
  let dateStr = DetailDateFormatting.formatDate(publishedAt)
  let escapedTitle = (title ?? "Untitled").htmlEscaped
  let escapedAuthor = (author ?? "").htmlEscaped
  let escapedDomain = (displayDomain ?? "").lowercased().htmlEscaped
  let body = stripFeedStyles(replaceVideoIframes(feedHTMLBody))
  let favicon = renderFaviconHTML(base64: faviconBase64, fallbackInitial: feedTitleInitial)
  // Four decimal places match the scale factors' own precision, and the
  // C locale keeps the CSS decimal separator a point in every locale.
  let scaleCSS = String(format: "%.4f", scaleFactor)

  return
    template
    .replacingOccurrences(of: "[[scale]]", with: scaleCSS)
    .replacingOccurrences(of: "[[style]]", with: css)
    .replacingOccurrences(of: "[[date]]", with: dateStr)
    .replacingOccurrences(of: "[[title]]", with: escapedTitle)
    .replacingOccurrences(of: "[[author]]", with: escapedAuthor)
    .replacingOccurrences(of: "[[domain]]", with: escapedDomain)
    .replacingOccurrences(of: "[[favicon]]", with: favicon)
    .replacingOccurrences(of: "[[body]]", with: body)
}

// MARK: - Favicon composition

/// Compose the favicon HTML for the article header: a base64 PNG when the feed
/// has one, and an initial-letter placeholder otherwise.
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

/// Patterns that strip feed CSS, scripts, event handlers and typing surfaces
/// from feed HTML. JavaScript is disabled in the web view, so this stripping is
/// the only defence. The pairs apply in order, case-insensitively, so uppercase
/// markup cannot slip through; most templates delete the match, and the
/// `contenteditable` rule keeps its captured tag prefix.
///
/// A plain HTML form control stays focusable and editable with JavaScript off,
/// and a click into one would put the in-page caret behind the bare-key routing
/// — typing there would act instead of type. Stripping the typing surfaces
/// makes "bare keys never fire while typing" true by construction.
nonisolated private let articleHTMLSanitizerPatterns: [(pattern: String, template: String)] = [
  ("<style[^>]*>[\\s\\S]*?</style>", ""),
  ("<link[^>]*rel=[\"']stylesheet[\"'][^>]*/?>", ""),
  ("<script[^>]*>[\\s\\S]*?</script>", ""),
  ("<input[^>]*>", ""),
  ("<textarea[^>]*>[\\s\\S]*?</textarea>", ""),
  ("<select[^>]*>[\\s\\S]*?</select>", ""),
  ("<button[^>]*>[\\s\\S]*?</button>", ""),
  ("\\s+on\\w+\\s*=\\s*\"[^\"]*\"", ""),
  ("\\s+on\\w+\\s*=\\s*'[^']*'", ""),
  ("\\s+style\\s*=\\s*\"[^\"]*\"", ""),
  ("\\s+style\\s*=\\s*'[^']*'", ""),
  // `contenteditable` turns any element into a typing surface. The captured
  // prefix anchors the rule inside a tag, so the word in article prose is never
  // touched, and the lookahead keeps a longer attribute name intact.
  (
    "(<[a-zA-Z][^>]*?)\\s+contenteditable(?![\\w-])(\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+))?",
    "$1"
  ),
]

nonisolated func stripFeedStyles(_ html: String) -> String {
  articleHTMLSanitizerPatterns.reduce(html) { result, rule in
    result.replacingOccurrences(
      of: rule.pattern, with: rule.template,
      options: [.regularExpression, .caseInsensitive])
  }
}
