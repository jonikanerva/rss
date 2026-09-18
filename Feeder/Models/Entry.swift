import Foundation
import SwiftData

/// The live `Entry` is whatever the latest `VersionedSchema` declares. The
/// `@Model` class is nested in that schema, and this typealias is how the rest
/// of the app refers to it. Re-point the typealias when the next schema version
/// lands, and the app picks up the new shape uniformly.
typealias Entry = FeederSchemaV2.Entry

extension Entry {
  fileprivate static let emptyContentMessage = "This article has no inline content."

  /// Feed-provided HTML for the web view, preferring the content over the
  /// summary. It must show what the feed provides; extracted content belongs in
  /// the reader view.
  var feedHTML: String {
    if let content, !content.isEmpty { return content }
    if let summary, !summary.isEmpty { return summary }
    return
      "<p class=\"empty-fallback\">\(Self.emptyContentMessage) <a href=\"\(url.htmlEscaped)\">Open in browser \u{2192}</a></p>"
  }
}
