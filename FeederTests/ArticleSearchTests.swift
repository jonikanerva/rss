import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Pins the article-list search: the term narrows the list to the entries
/// whose title, site name, or summary matches, ignores case and diacritics,
/// matches special characters literally, and never changes the canonical
/// order or the paging seams. The production writer and reader run on one
/// shared in-memory container (`STACK.md § 14`).
@Suite("Article search", .serialized)
struct ArticleSearchTests {
  private static let base = Date(timeIntervalSince1970: 1_750_000_000)

  private static func published(secondsBeforeBase seconds: Int) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: base.addingTimeInterval(-Double(seconds)))
  }

  private struct Row {
    let id: Int
    var feedId = 100
    var title: String? = "Plain story"
    var summary: String?
    var read = false
    var category = "tech"
  }

  /// Feed 100 has the site `example.com`; feed 200 has `quietsite.net`. A
  /// smaller `id` is older, so the canonical order is descending `id`.
  private func seed(_ rows: [Row]) async throws -> (DataWriter, DataReader) {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    try await writer.syncFeeds([
      FeedbinFixtures.subscription(),
      FeedbinFixtures.subscription(
        id: 2, feedId: 200, title: "Quiet", feedUrl: "https://quietsite.net/feed",
        siteUrl: "https://quietsite.net"),
    ])
    try await writer.addCategory(label: "tech", displayName: "Tech", description: "Tech", sortOrder: 0)
    try await writer.addCategory(label: "other", displayName: "Other", description: "Other", sortOrder: 1)
    let entries = try rows.map { row in
      try FeedbinFixtures.entry(
        id: row.id, feedId: row.feedId, title: row.title, content: "<p>Body text \(row.id)</p>",
        summary: row.summary, published: Self.published(secondsBeforeBase: 10_000 - row.id))
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(rows.filter { !$0.read }.map(\.id)))
    for row in rows {
      try await writer.applyClassification(
        entryID: row.id, result: ClassificationResult(entryID: row.id, categoryLabel: row.category))
    }
    return (writer, reader)
  }

  private func ids(
    _ reader: DataReader, _ text: String, scope: EntryScope = .all, showRead: Bool = false,
    pinned: Int? = nil, window: EntryListWindow = .firstPage(limit: 50)
  ) async throws -> [Int] {
    let result = try await reader.fetchEntrySections(
      scope: scope, showRead: showRead, cutoffDate: .distantPast, search: ArticleSearchTerm(text),
      pinnedFeedbinEntryID: pinned, window: window)
    return result.sections.flatMap(\.rows).map(\.feedbinEntryID)
  }

  @Test("An empty or whitespace-only term is no search")
  func blankTermIsNoSearch() {
    #expect(ArticleSearchTerm("") == nil)
    #expect(ArticleSearchTerm("  \n\t") == nil)
    #expect(ArticleSearchTerm("  swift ")?.text == "swift")
  }

  /// Mark All as Read reads `typedTerm`, so a write that starts inside the
  /// typing pause follows the field, not the term of the shown rows.
  @MainActor
  @Test("The typed term leads the committed term until the typing pause ends")
  func typedTermLeadsCommittedTerm() {
    let state = ArticleSearchState()
    state.text = "swift"
    #expect(state.typedTerm?.text == "swift")
    #expect(state.term == nil)
    state.commitTypedTerm()
    #expect(state.term?.text == "swift")
    state.text = "  "
    state.commitTypedTerm()
    #expect(state.term == nil)
  }

  @Test("The term matches the title, the site name, and the summary only")
  func matchesTitleSiteAndSummary() async throws {
    let (_, reader) = try await seed([
      Row(id: 1, title: "Swift concurrency notes"),
      Row(id: 2, feedId: 200, title: "Unrelated"),
      Row(id: 3, title: "Other", summary: "<p>A note about swift macros</p>"),
      Row(id: 4, title: "Nothing here"),
    ])
    #expect(try await ids(reader, "swift") == [3, 1])
    #expect(try await ids(reader, "quietsite") == [2])
    // The full article body holds "Body text 4" but is not part of the match.
    #expect(try await ids(reader, "Body text").isEmpty)
  }

  @Test("The match ignores letter case and diacritics")
  func ignoresCaseAndDiacritics() async throws {
    let (_, reader) = try await seed([
      Row(id: 1, title: "Café culture"),
      Row(id: 2, title: "Plain"),
    ])
    #expect(try await ids(reader, "CAFE") == [1])
    #expect(try await ids(reader, "café") == [1])
  }

  @Test("Special characters match literally")
  func specialCharactersMatchLiterally() async throws {
    let (_, reader) = try await seed([
      Row(id: 1, title: "100% done"),
      Row(id: 2, title: "1000 done"),
      Row(id: 3, title: "snake_case"),
      Row(id: 4, title: "snakeXcase"),
      Row(id: 5, title: "a*b"),
      Row(id: 6, title: "say \"hi\""),
    ])
    #expect(try await ids(reader, "100%") == [1])
    #expect(try await ids(reader, "e_c") == [3])
    #expect(try await ids(reader, "a*b") == [5])
    #expect(try await ids(reader, "\"hi\"") == [6])
  }

  @Test("The search keeps the scope, the read filter, and the canonical order")
  func keepsScopeFilterAndOrder() async throws {
    let (_, reader) = try await seed([
      Row(id: 1, title: "Mac story"),
      Row(id: 2, title: "Mac story", read: true),
      Row(id: 3, title: "Mac story", category: "other"),
      Row(id: 4, title: "Mac story"),
      Row(id: 5, title: "Linux story"),
    ])
    #expect(try await ids(reader, "mac", scope: .category("tech")) == [4, 1])
    #expect(try await ids(reader, "mac", scope: .category("tech"), showRead: true) == [2])
    #expect(try await ids(reader, "mac") == [4, 3, 1])
  }

  @Test("Pages of a search tile with no gap and no duplicate")
  func pagesTile() async throws {
    let rows = (1...9).map { Row(id: $0, title: $0.isMultiple(of: 2) ? "Other" : "Match \($0)") }
    let (_, reader) = try await seed(rows)
    let first = try await reader.fetchEntrySections(
      scope: .all, showRead: false, cutoffDate: .distantPast, search: ArticleSearchTerm("match"),
      window: .firstPage(limit: 2))
    #expect(first.hasMore)
    let cursor = try #require(entryListCursor(of: first.sections))
    let rest = try await ids(reader, "match", window: .after(cursor, limit: 10))
    #expect(first.sections.flatMap(\.rows).map(\.feedbinEntryID) + rest == [9, 7, 5, 3, 1])
  }

  @Test("A pinned row stays only when it matches the term")
  func pinnedRowNeedsMatch() async throws {
    let (_, reader) = try await seed([
      Row(id: 1, title: "Match", read: true),
      Row(id: 2, title: "Other", read: true),
      Row(id: 3, title: "Match"),
    ])
    #expect(try await ids(reader, "match", pinned: 1) == [3, 1])
    #expect(try await ids(reader, "match", pinned: 2) == [3])
  }

  @Test("The unread IDs of a scope narrow to the matches")
  func unreadIDsNarrow() async throws {
    let (writer, _) = try await seed([
      Row(id: 1, title: "Match"),
      Row(id: 2, title: "Other"),
      Row(id: 3, title: "Match", read: true),
      Row(id: 4, title: "Match", category: "other"),
    ])
    #expect(
      try await writer.fetchUnreadEntryIDs(
        in: .category("tech"), cutoffDate: .distantPast, search: ArticleSearchTerm("match")) == [1])
    #expect(
      try await writer.fetchUnreadEntryIDs(in: .category("tech"), cutoffDate: .distantPast) == [1, 2])
  }
}
