import Foundation
import SwiftData

/// Live `Entry` is whatever the latest `VersionedSchema` declares. The
/// `@Model` class itself lives nested in `FeederSchemaV2.Entry`; this
/// typealias is how the rest of the app refers to it without paying
/// the cost of qualifying every reference. When the next schema version
/// lands, re-point this typealias to `FeederSchemaVN.Entry` and the
/// app picks up the new shape uniformly.
typealias Entry = FeederSchemaV2.Entry

extension Entry {
  fileprivate static let emptyContentMessage = "This article has no inline content."

  /// Feed-provided HTML for the default web view: content > summary.
  /// Always shows what the feed provides — extracted content belongs in reader view.
  var feedHTML: String {
    if let content, !content.isEmpty { return content }
    if let summary, !summary.isEmpty { return summary }
    return
      "<p class=\"empty-fallback\">\(Self.emptyContentMessage) <a href=\"\(url.htmlEscaped)\">Open in browser \u{2192}</a></p>"
  }
}
