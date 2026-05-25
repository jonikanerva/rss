import Foundation
import Testing

@testable import Feeder

// MARK: - DataWriter.fetchUnreadCountsSnapshot

/// Integration coverage for the unread aggregation that replaces the
/// MainActor `@Query unreadEntries` fetch. The snapshot is the sole input the
/// sidebar reads for badge counts, so its contract — empty case, mixed
/// read/unread, multi-axis grouping — is what these tests pin down.
struct UnreadCountsSnapshotFetchTests {
  private func makeWriter() async throws -> DataWriter {
    try await DataWriterTestSupport.makeWriter()
  }

  private func seedFeed(_ writer: DataWriter, id: Int = 1, feedId: Int = 100) async throws {
    let sub = try FeedbinFixtures.subscription(id: id, feedId: feedId)
    try await writer.syncFeeds([sub])
  }

  private func seedTaxonomy(_ writer: DataWriter) async throws {
    try await writer.addFolder(label: "tech", displayName: "Tech", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple", sortOrder: 0, folderLabel: "tech")
    try await writer.addCategory(
      label: "playstation", displayName: "PlayStation",
      description: "Gaming", sortOrder: 1, folderLabel: "tech")
    try await writer.addCategory(
      label: "world_news", displayName: "World News",
      description: "World news", sortOrder: 2)
  }

  private func classify(_ writer: DataWriter, id: Int, category: String) async throws {
    let result = ClassificationResult(
      entryID: id, categoryLabel: category,
      detectedLanguage: "en", confidence: 0.9)
    try await writer.applyClassification(entryID: id, result: result)
  }

  @Test
  func emptyStoreReturnsEmptySnapshot() async throws {
    let writer = try await makeWriter()
    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot == UnreadCountsSnapshot.empty)
  }

  @Test
  func unclassifiedEntriesDoNotContribute() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)
    let entry = try FeedbinFixtures.entry(id: 9001)
    _ = try await writer.persistEntries([entry], unreadIDs: Set([9001]))
    // No applyClassification — entry stays `isClassified == false`.
    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.totalUnread == 0)
    #expect(snapshot.categoryCounts.isEmpty)
    #expect(snapshot.folderCounts.isEmpty)
    #expect(snapshot.unreadFeedbinEntryIDs.isEmpty)
  }

  @Test
  func readEntriesDoNotContribute() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)
    try await seedTaxonomy(writer)

    let unread = try FeedbinFixtures.entry(id: 1101, title: "Unread")
    let read = try FeedbinFixtures.entry(id: 1102, title: "Read")
    _ = try await writer.persistEntries([unread, read], unreadIDs: Set([1101]))
    try await classify(writer, id: 1101, category: "apple")
    try await classify(writer, id: 1102, category: "apple")

    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.totalUnread == 1)
    #expect(snapshot.categoryCounts["apple"] == 1)
    #expect(snapshot.folderCounts["tech"] == 1)
    #expect(snapshot.unreadFeedbinEntryIDs == [1101])
    #expect(snapshot.unreadIDByCategory["apple"] == [1101])
    #expect(snapshot.unreadIDByFolder["tech"] == [1101])
  }

  @Test
  func multipleEntriesPerCategoryAggregate() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)
    try await seedTaxonomy(writer)

    let entries = [
      try FeedbinFixtures.entry(id: 2201, title: "Apple 1"),
      try FeedbinFixtures.entry(id: 2202, title: "Apple 2"),
      try FeedbinFixtures.entry(id: 2203, title: "Apple 3"),
      try FeedbinFixtures.entry(id: 2204, title: "PlayStation 1"),
      try FeedbinFixtures.entry(id: 2205, title: "World 1"),
    ]
    _ = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))
    try await classify(writer, id: 2201, category: "apple")
    try await classify(writer, id: 2202, category: "apple")
    try await classify(writer, id: 2203, category: "apple")
    try await classify(writer, id: 2204, category: "playstation")
    try await classify(writer, id: 2205, category: "world_news")

    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.totalUnread == 5)
    #expect(snapshot.categoryCounts["apple"] == 3)
    #expect(snapshot.categoryCounts["playstation"] == 1)
    #expect(snapshot.categoryCounts["world_news"] == 1)
    // `world_news` is a root-level category — no folder contribution.
    #expect(snapshot.folderCounts["tech"] == 4)
    #expect(snapshot.folderCounts["world_news"] == nil)
    #expect(snapshot.unreadIDByCategory["apple"] == [2201, 2202, 2203])
    #expect(snapshot.unreadIDByCategory["playstation"] == [2204])
    #expect(snapshot.unreadIDByFolder["tech"] == [2201, 2202, 2203, 2204])
    #expect(snapshot.unreadFeedbinEntryIDs == [2201, 2202, 2203, 2204, 2205])
  }

  @Test
  func rootCategoryEntriesContributeToCategoryButNotFolder() async throws {
    // Mirrors the `applyClassificationSetsPrimaryFolderForRootCategory` rule:
    // a root-level category has `primaryFolder == ""`, which must not
    // contribute to any folder bucket — `[String: Int]` must not gain an
    // empty-string key.
    let writer = try await makeWriter()
    try await seedFeed(writer)
    try await writer.addCategory(
      label: "world_news", displayName: "World News",
      description: "World", sortOrder: 0)

    let entry = try FeedbinFixtures.entry(id: 3301, title: "World 1")
    _ = try await writer.persistEntries([entry], unreadIDs: Set([3301]))
    try await classify(writer, id: 3301, category: "world_news")

    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: .distantPast)
    #expect(snapshot.categoryCounts["world_news"] == 1)
    #expect(snapshot.folderCounts.isEmpty)
    #expect(snapshot.unreadIDByFolder.isEmpty)
  }

  /// Regression pin for the PR #103 sidebar/list cutoff asymmetry: the
  /// snapshot's predicate must include the same `publishedAt >= cutoffDate`
  /// clause that `fetchEntrySections` applies. Without it, entries between
  /// `articleKeepDays` (default 7d) and `maxRetentionAge` (30d) get counted
  /// in the sidebar but hidden from the list.
  @Test
  func snapshotExcludesPreCutoffUnreadEntries() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)
    try await seedTaxonomy(writer)

    let oldEntry = try FeedbinFixtures.entry(
      id: 4401, title: "Stale", published: "2020-01-01T00:00:00.000000Z")
    let freshEntry = try FeedbinFixtures.entry(
      id: 4402, title: "Recent", published: "2030-01-01T00:00:00.000000Z")
    _ = try await writer.persistEntries(
      [oldEntry, freshEntry], unreadIDs: Set([4401, 4402]))
    try await classify(writer, id: 4401, category: "apple")
    try await classify(writer, id: 4402, category: "apple")

    // Cutoff sits between the two seeded entries — only the 2030 row is
    // eligible.
    let isoFormatter = ISO8601DateFormatter()
    let cutoff = isoFormatter.date(from: "2025-01-01T00:00:00Z")!

    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
    #expect(snapshot.totalUnread == 1)
    #expect(snapshot.unreadFeedbinEntryIDs == [4402])
    #expect(snapshot.unreadFeedbinEntryIDs.contains(4401) == false)
    #expect(snapshot.categoryCounts["apple"] == 1)
    #expect(snapshot.unreadIDByCategory["apple"] == [4402])
    #expect(snapshot.folderCounts["tech"] == 1)
  }

  /// Parity check: the snapshot and `fetchEntrySections` must agree on the
  /// same unread+classified row set when called with the same `cutoffDate`.
  /// This is the contract the production code depends on — sidebar badge
  /// equals the article-list row count for the same category.
  @Test
  func snapshotMatchesFetchEntrySectionsUnderSameCutoff() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)
    try await seedTaxonomy(writer)

    let preCutoff = try FeedbinFixtures.entry(
      id: 5501, title: "Pre A", published: "2020-01-01T00:00:00.000000Z")
    let postCutoffOne = try FeedbinFixtures.entry(
      id: 5502, title: "Post A", published: "2030-01-01T00:00:00.000000Z")
    let postCutoffTwo = try FeedbinFixtures.entry(
      id: 5503, title: "Post B", published: "2030-02-01T00:00:00.000000Z")
    _ = try await writer.persistEntries(
      [preCutoff, postCutoffOne, postCutoffTwo],
      unreadIDs: Set([5501, 5502, 5503]))
    try await classify(writer, id: 5501, category: "apple")
    try await classify(writer, id: 5502, category: "apple")
    try await classify(writer, id: 5503, category: "apple")

    let isoFormatter = ISO8601DateFormatter()
    let cutoff = isoFormatter.date(from: "2025-01-01T00:00:00Z")!

    let snapshot = try await writer.fetchUnreadCountsSnapshot(cutoffDate: cutoff)
    let sections = try await writer.fetchEntrySections(
      category: "apple", folder: nil, showRead: false,
      cutoffDate: cutoff, pinnedFeedbinEntryID: nil
    )
    let sectionRowCount = sections.flatMap(\.entryIDs).count

    #expect(snapshot.categoryCounts["apple"] == sectionRowCount)
    #expect(snapshot.categoryCounts["apple"] == 2)
    #expect(sectionRowCount == 2)
  }
}
