import Foundation
import Testing

@testable import Feeder

/// Pins `VISION.md → Core Principles`: every timeline is `publishedAt`
/// descending with the `feedbinEntryID` tiebreak, and classification never
/// moves an article. The production writer and reader share one in-memory
/// container, and `ClassificationRunner` with a fake provider drains the
/// backlog.
@Suite("Chronology is canonical", .serialized)
struct ChronologyTests {
  /// One fixture article, with its timestamps in seconds from `base`.
  private struct Article {
    let id: Int
    let title: String
    let published: Int
    let created: Int
  }

  private static let base = Date(timeIntervalSince1970: 1_750_000_000)

  /// Persisted in this order. In every asserted timeline of two or more rows,
  /// the expected order must differ from the newest-first `createdAt` order,
  /// the insertion order, and the descending `feedbinEntryID` order, or a
  /// reader that sorts by one of them passes. Delta and Echo share a
  /// `publishedAt`.
  private static let articles: [Article] = [
    Article(id: 1004, title: "Delta", published: -300, created: -300),
    Article(id: 1007, title: "Golf fails", published: -900, created: 600),
    Article(id: 1002, title: "Bravo", published: -120, created: -50),
    Article(id: 1005, title: "Echo", published: -300, created: -310),
    Article(id: 1003, title: "Charlie", published: -600, created: 300),
    Article(id: 1006, title: "Foxtrot fails", published: -30, created: -30),
    Article(id: 1001, title: "Alpha", published: -60, created: -60),
  ]

  @Test
  func classificationNeverMovesAnArticleInTheTimeline() async throws {
    let (writer, reader) = try await DataWriterTestSupport.makeWriterAndReader()
    try await writer.syncFeeds([FeedbinFixtures.subscription()])
    try await writer.addFolder(label: "news", displayName: "News", sortOrder: 0)
    try await writer.addCategory(
      label: "tech", displayName: "Tech", description: "Technology news", sortOrder: 0, folderLabel: "news")
    try await writer.addCategory(
      label: "science", displayName: "Science", description: "Science news", sortOrder: 1, folderLabel: "news")
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized", description: "Fallback", sortOrder: 2)
    let entries = try Self.articles.map { article in
      try FeedbinFixtures.entry(
        id: article.id, title: article.title,
        published: formatDateForFeedbin(Self.base.addingTimeInterval(Double(article.published))),
        createdAt: formatDateForFeedbin(Self.base.addingTimeInterval(Double(article.created))))
    }
    _ = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))

    // Two rows classified one at a time, in the reverse of their timeline order.
    for id in [1002, 1001] {
      try await writer.applyClassification(
        entryID: id, result: ClassificationResult(entryID: id, categoryLabel: "tech"))
    }
    #expect(try await timeline(reader, folder: "news") == [1001, 1002])

    // The drain sends the rest to the fake, which answers "tech" and fails the
    // two titles below, so those rows take the explicit fallback.
    let provider = FakeClassificationProvider()
    for title in ["Foxtrot fails", "Golf fails"] {
      await provider.configureFailure(FakeClassificationFailure(batchAbort: nil), forTitle: title)
    }
    let runner = ClassificationRunner(writer: writer, providerFactory: { provider }, reportProgress: { _ in })
    guard case .completed(5) = await runner.runOneBatch(cutoffDate: .distantPast) else {
      Issue.record("The drain did not classify the five pending rows")
      return
    }
    let requestedTitles = await provider.requestedTitles
    let drainOrder = try requestedTitles.map { title in
      try #require(Self.articles.first { $0.title == title }).id
    }
    // A drain in timeline order would let a reader that follows the write
    // order pass.
    try #require(drainOrder != [1006, 1005, 1004, 1003, 1007], "drain order \(drainOrder)")

    let newsTimeline = [1001, 1002, 1005, 1004, 1003]
    #expect(try await timeline(reader, folder: "news") == newsTimeline)
    #expect(try await timeline(reader, category: "tech") == newsTimeline)
    #expect(try await timeline(reader, category: uncategorizedLabel) == [1006, 1007])
    try await expectFixturePublishedAt(reader)

    // A move to another category of the same folder keeps the folder timeline.
    try await writer.applyClassification(
      entryID: 1005, result: ClassificationResult(entryID: 1005, categoryLabel: "science"))
    #expect(try await timeline(reader, folder: "news") == newsTimeline)
    #expect(try await timeline(reader, category: "tech") == [1001, 1002, 1004, 1003])
    #expect(try await timeline(reader, category: "science") == [1005])
    try await expectFixturePublishedAt(reader)
  }

  // MARK: - Helpers

  /// The rows of one timeline, flattened across its day sections, which depend
  /// on the local day boundaries.
  private func rows(_ reader: DataReader, category: String? = nil, folder: String? = nil) async throws -> [EntryRowDTO] {
    try await reader.fetchEntrySections(
      category: category, folder: folder, showRead: false, cutoffDate: .distantPast,
      window: .firstPage(limit: 100)
    ).sections.flatMap(\.rows)
  }

  private func timeline(_ reader: DataReader, category: String? = nil, folder: String? = nil) async throws -> [Int] {
    try await rows(reader, category: category, folder: folder).map(\.feedbinEntryID)
  }

  private func expectFixturePublishedAt(_ reader: DataReader) async throws {
    let rows = try await rows(reader, folder: "news") + rows(reader, category: uncategorizedLabel)
    #expect(rows.count == Self.articles.count)
    for row in rows {
      let article = try #require(Self.articles.first { $0.id == row.feedbinEntryID })
      #expect(
        row.publishedAt == Self.base.addingTimeInterval(Double(article.published)),
        "entry \(row.feedbinEntryID) publishedAt \(row.publishedAt)")
    }
  }
}
