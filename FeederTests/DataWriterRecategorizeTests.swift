import Foundation
import Testing

@testable import Feeder

// MARK: - DataWriter Recategorize Tests
//
// Covers `DataWriter.removeCategoryAndReassignArticles(_:to:)` and the
// companion `countEntries(primaryCategoryLabel:)` helper. The two together
// back the confirmation-dialog flow added to `CategoryEditSheet` for #102:
// zero orphans → no dialog; positive orphans → reassign + delete in one
// atomic transaction.

struct DataWriterRecategorizeTests {
  // MARK: - Helpers

  private func makeWriter() async throws -> DataWriter {
    try await DataWriterTestSupport.makeWriter()
  }

  /// Seed two categories in the same folder plus a feed, so tests can persist
  /// classified entries against either label.
  private func seedTwoCategoriesAndFeed(_ writer: DataWriter) async throws {
    try await writer.addFolder(label: "technology", displayName: "Technology", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple Inc.", sortOrder: 0, folderLabel: "technology"
    )
    try await writer.addCategory(
      label: "ai", displayName: "AI",
      description: "AI news", sortOrder: 1, folderLabel: "technology"
    )
    let sub = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([sub])
  }

  /// Persist N entries into a single category. Each classified entry carries
  /// the category's label as `primaryCategory` and the folder as `primaryFolder`.
  @discardableResult
  private func seedClassifiedEntries(
    _ writer: DataWriter, count: Int, categoryLabel: String, folderLabel: String,
    startingID: Int = 1000
  ) async throws -> [Int] {
    var ids: [Int] = []
    for i in 0..<count {
      let id = startingID + i
      let entry = try FeedbinFixtures.entry(id: id, title: "Entry \(id)")
      _ = try await writer.persistEntries([entry], unreadIDs: Set([id]))
      try await writer.applyClassification(
        entryID: id,
        result: ClassificationResult(
          entryID: id, categoryLabel: categoryLabel, confidence: 0.9
        )
      )
      // Sanity check: applyClassification put the entry in the expected place.
      let snap = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snap?.primaryCategory == categoryLabel)
      #expect(snap?.primaryFolder == folderLabel)
      ids.append(id)
    }
    return ids
  }

  // MARK: - countEntries

  @Test
  func countEntriesReturnsZeroForCategoryWithoutOrphans() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    // No entries persisted yet — count must be 0.
    let count = try await writer.countEntries(primaryCategoryLabel: "apple")
    #expect(count == 0)
  }

  @Test
  func countEntriesReturnsExactAssignedCount() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    _ = try await seedClassifiedEntries(
      writer, count: 4, categoryLabel: "apple", folderLabel: "technology"
    )
    // One stray entry assigned to ai so the predicate has to discriminate.
    _ = try await seedClassifiedEntries(
      writer, count: 1, categoryLabel: "ai", folderLabel: "technology",
      startingID: 2000
    )
    let appleCount = try await writer.countEntries(primaryCategoryLabel: "apple")
    let aiCount = try await writer.countEntries(primaryCategoryLabel: "ai")
    #expect(appleCount == 4)
    #expect(aiCount == 1)
  }

  // MARK: - removeCategoryAndReassignArticles — happy path

  @Test
  func removeCategoryReassignsAllOrphansAndDeletesSource() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    let ids = try await seedClassifiedEntries(
      writer, count: 3, categoryLabel: "apple", folderLabel: "technology"
    )

    let outcome = try await writer.removeCategoryAndReassignArticles("apple", to: "ai")
    #expect(outcome.reassignedCount == 3)
    #expect(outcome.targetFolderLabel == "technology")

    // Source gone.
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(!defs.contains { $0.label == "apple" })

    // Every entry now lives in the target.
    for id in ids {
      let snap = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snap?.primaryCategory == "ai")
      #expect(snap?.primaryFolder == "technology")
    }
  }

  @Test
  func removeCategoryWithRootTargetClearsPrimaryFolder() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    // Root-level target — no folder, so reassigned entries should lose their folder too.
    try await writer.addCategory(
      label: "world_news", displayName: "World News",
      description: "World affairs", sortOrder: 0
    )
    let ids = try await seedClassifiedEntries(
      writer, count: 2, categoryLabel: "apple", folderLabel: "technology"
    )

    let outcome = try await writer.removeCategoryAndReassignArticles(
      "apple", to: "world_news"
    )
    #expect(outcome.reassignedCount == 2)
    #expect(outcome.targetFolderLabel == "")

    for id in ids {
      let snap = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snap?.primaryCategory == "world_news")
      #expect(snap?.primaryFolder == "")
    }
  }

  @Test
  func removeCategoryWithZeroOrphansStillDeletesSource() async throws {
    // The dialog UI skips empty categories, but the writer must remain safe
    // if a caller invokes the reassign flow with zero orphans anyway.
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)

    let outcome = try await writer.removeCategoryAndReassignArticles("apple", to: "ai")
    #expect(outcome.reassignedCount == 0)
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(!defs.contains { $0.label == "apple" })
  }

  // MARK: - removeCategoryAndReassignArticles — error paths

  @Test
  func removeCategoryThrowsWhenSourceMissing() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    await #expect(throws: CategoryReassignError.sourceMissing) {
      _ = try await writer.removeCategoryAndReassignArticles("ghost", to: "ai")
    }
  }

  @Test
  func removeCategoryThrowsWhenTargetMissing() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    await #expect(throws: CategoryReassignError.targetMissing) {
      _ = try await writer.removeCategoryAndReassignArticles("apple", to: "ghost")
    }
  }

  @Test
  func removeCategoryThrowsWhenSourceEqualsTarget() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    await #expect(throws: CategoryReassignError.sourceEqualsTarget) {
      _ = try await writer.removeCategoryAndReassignArticles("apple", to: "apple")
    }
  }

  @Test
  func removeCategoryRefusesToDeleteSystemSource() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    try await writer.addCategory(
      label: uncategorizedLabel, displayName: "Uncategorized",
      description: "Fallback", sortOrder: Int.max
    )
    try await writer.updateSystemFlag(label: uncategorizedLabel, isSystem: true)

    await #expect(throws: CategoryReassignError.sourceIsSystem) {
      _ = try await writer.removeCategoryAndReassignArticles(uncategorizedLabel, to: "apple")
    }
    // System category must still exist.
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  // MARK: - Atomicity

  /// On an error path nothing must be left half-applied — neither the source
  /// nor the target moves, and no entry flips category. The store after a
  /// failing call should be byte-equivalent to the store before it.
  @Test
  func removeCategoryFailureLeavesStoreUntouched() async throws {
    let writer = try await makeWriter()
    try await seedTwoCategoriesAndFeed(writer)
    let ids = try await seedClassifiedEntries(
      writer, count: 2, categoryLabel: "apple", folderLabel: "technology"
    )

    await #expect(throws: CategoryReassignError.targetMissing) {
      _ = try await writer.removeCategoryAndReassignArticles("apple", to: "ghost")
    }

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == "apple" })
    for id in ids {
      let snap = try await writer.fetchEntrySnapshot(feedbinEntryID: id)
      #expect(snap?.primaryCategory == "apple")
      #expect(snap?.primaryFolder == "technology")
    }
  }
}
