import Foundation

/// Decode persisted article block JSON into the in-memory `[ArticleBlock]` model used by the
/// reader view. Pure function — same input, same output, no side effects. `nonisolated` so the
/// caller may invoke it from any actor (typically `EntryDetailView.task` on MainActor; the JSON
/// blobs are small enough — 30–100 KB — that a synchronous decode in the task body costs <1 ms
/// and avoids a loading-state flash on entry switch).
///
/// Falls back gracefully when persisted data is missing or unreadable:
///   • `data` decodes to a non-empty `[ArticleBlock]` → return as-is.
///   • `data` is nil, decodes to empty, or fails decoding → synthesize a fallback containing the
///     pre-stripped `plainText` (if any) followed by an "Open in browser" markdown link.
///   • Empty `plainText` + missing `data` → minimal fallback with just the "Open in browser" link.
///
/// The "Open in browser" affordance is always present in the fallback so the user can recover when
/// there is no rendered content to read.
nonisolated func decodeBlocks(
  data: Data?,
  fallbackPlainText: String,
  fallbackURL: String
) -> [ArticleBlock] {
  if let data, let decoded = [ArticleBlock].from(data), !decoded.isEmpty {
    return decoded
  }
  return fallbackBlocks(plainText: fallbackPlainText, url: fallbackURL)
}

private nonisolated func fallbackBlocks(plainText: String, url: String) -> [ArticleBlock] {
  let openInBrowser = "[Open in browser \u{2192}](\(url))"
  if plainText.isEmpty {
    return [.paragraph(text: openInBrowser)]
  }
  return [
    .paragraph(text: plainText),
    .paragraph(text: openInBrowser),
  ]
}
