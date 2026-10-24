import Foundation
import SwiftData

/// A search term that narrows one article list. The term matches the title,
/// the site name, and the summary text of an entry, and ignores letter case
/// and diacritics. The term is never persisted or logged.
nonisolated struct ArticleSearchTerm: Sendable, Hashable {
  let text: String

  /// Returns nil for an empty or whitespace-only term: that state is no search.
  init?(_ rawText: String) {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    text = trimmed
  }

  /// The match clause as a SQLite-level predicate. The full article body is
  /// not part of the match.
  var predicate: Predicate<Entry> {
    let text = text
    return #Predicate<Entry> {
      ($0.title?.localizedStandardContains(text) ?? false)
        || ($0.displayDomain?.localizedStandardContains(text) ?? false)
        || $0.summaryPlainText.localizedStandardContains(text)
    }
  }

  /// `base` narrowed to the entries that match `term`. A nil term returns `base`.
  static func narrowing(_ base: Predicate<Entry>, to term: ArticleSearchTerm?) -> Predicate<Entry> {
    guard let match = term?.predicate else { return base }
    return #Predicate<Entry> { base.evaluate($0) && match.evaluate($0) }
  }
}
