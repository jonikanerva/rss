import Foundation

@testable import Feeder

/// Shared Feedbin DTO builders used across the test target. Each helper goes
/// through the production `makeFeedbinDecoder()` so tests exercise the same
/// key-decoding strategy and date format the real API path uses.
enum FeedbinFixtures {
  /// Build a `FeedbinSubscription`. Defaults match the values
  /// `DataWriterEntryTests` and `DataWriterBootstrapTests` historically
  /// constructed by hand.
  static func subscription(
    id: Int = 1,
    feedId: Int = 100,
    title: String = "Test Feed",
    feedUrl: String = "https://example.com/feed.xml",
    siteUrl: String = "https://www.example.com",
    createdAt: String = "2025-01-01T00:00:00.000000Z"
  ) throws -> FeedbinSubscription {
    let json: [String: Any] = [
      "id": id,
      "feed_id": feedId,
      "title": title,
      "feed_url": feedUrl,
      "site_url": siteUrl,
      "created_at": createdAt,
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinSubscription.self, from: data)
  }

  /// Build a `FeedbinEntry`. `title` and `content` are optional so callers
  /// can construct the "missing fields" cases that exercise decoder
  /// fallbacks. `published` doubles as `created_at` — both fields are
  /// required by `FeedbinEntry` but the tests rarely care that they differ.
  static func entry(
    id: Int = 1001,
    feedId: Int = 100,
    title: String? = "Test Article",
    content: String? = "<p>Hello <b>world</b></p>",
    url: String = "https://example.com/article",
    published: String = "2025-06-15T12:00:00.000000Z"
  ) throws -> FeedbinEntry {
    var json: [String: Any] = [
      "id": id,
      "feed_id": feedId,
      "url": url,
      "published": published,
      "created_at": published,
    ]
    if let title { json["title"] = title }
    if let content { json["content"] = content }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinEntry.self, from: data)
  }

  /// Wrap a list of entries into a single-page `FeedbinEntriesPage`. Used by
  /// `SyncEngineTests` to drive the engine's paginated entry fetch through a
  /// fake client.
  static func entriesPage(
    _ entries: [FeedbinEntry],
    hasNextPage: Bool = false,
    totalCount: Int? = nil
  ) -> FeedbinEntriesPage {
    FeedbinEntriesPage(
      entries: entries,
      hasNextPage: hasNextPage,
      totalCount: totalCount ?? entries.count
    )
  }
}
