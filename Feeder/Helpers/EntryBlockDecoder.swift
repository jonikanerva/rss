import Foundation

/// Decode the persisted article block JSON into the reader view's model. Pure
/// and `nonisolated`, so any actor may call it; the blobs are small enough that
/// a synchronous decode avoids a loading flash on an entry switch.
///
/// Missing, empty or unreadable data falls back to the pre-stripped plain text,
/// if any. The fallback always ends with an "Open in browser" link, so the user
/// can recover when there is nothing rendered to read.
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
