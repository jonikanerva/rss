import Foundation

// MARK: - Article HTML rendering

/// Pure, MainActor-free renderer for the article web view.
///
/// The regex-heavy sanitization passes and the seven template-injection
/// passes used to live on `ArticleWebView`, which is `@MainActor`. Moving
/// them into a `nonisolated` helper lets `Task.detached` run them on a
/// background cooperative thread, keeping the render path off the
/// MainActor. All inputs are plain `Sendable` values (`String`, `Date`,
/// `Character`, `CGFloat`) so the helper can be invoked from any
/// isolation domain.
///
/// `scaleFactor` is the same multiplier `AppFontSettings` applies to every
/// SwiftUI font alias. Injecting it into the article HTML as the CSS custom
/// property `--app-scale` makes the WebView reader pane scale in lockstep
/// with the SwiftUI surfaces driven by the user's Appearance picker.
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
  // Format with up to four decimal places (matches the precision of the
  // `AppTextSize.scaleFactor` rationals). `String(format:)` uses the C
  // locale so the resulting CSS is always `1.15`, never `1,15`.
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

/// Patterns that strip feed CSS, scripts, event handlers, and in-page typing
/// surfaces from feed HTML.
/// JS is fully disabled in the web view, so this stripping is the only defence.
/// Each `(pattern, template)` pair is applied in order via
/// `replacingOccurrences(options: [.regularExpression, .caseInsensitive])`,
/// which uses `NSRegularExpression` under the hood — a value-type-safe API that
/// does not require carrying a non-`Sendable` `Regex<>` across actor boundaries.
/// Case-insensitive so uppercase markup (`<INPUT>`, `ONCLICK=`) cannot slip
/// through; most templates are empty (delete the match), the `contenteditable`
/// rule keeps its captured tag prefix.
///
/// Typing surfaces (`<input>`, `<textarea>`, `<select>`, `<button>`,
/// `contenteditable`) are stripped because a plain HTML form control is
/// focusable and editable even with JS off: a click into one would put the
/// in-page caret behind the bare-key routing in `ArticleWebView`, so typing
/// r/b there would act instead of type. Stripping makes "bare keys never
/// fire while typing" true by construction — and forms are dead weight in a
/// JS-off reading pane anyway (B opens the article in the browser).
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
  // `contenteditable` turns any element into a typing surface. The rule is
  // anchored inside a tag via the captured prefix (`[^>]*?` cannot cross a
  // `>`), so the word "contenteditable" in article prose is never touched;
  // covers double-quoted, single-quoted, unquoted, and bare-attribute forms.
  // The lookahead keeps `contenteditable`-prefixed attribute names intact.
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
