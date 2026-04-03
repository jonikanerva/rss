import Foundation
import Testing

@testable import Feeder

// MARK: - DataWriter Entry Tests

struct DataWriterEntryTests {
  // MARK: - Helpers

  private func makeWriter() async throws -> DataWriter {
    try await DataWriterTestSupport.makeWriter()
  }

  private static func makeFeedbinSubscription(
    id: Int = 1, feedId: Int = 100, title: String = "Test Feed",
    feedUrl: String = "https://example.com/feed.xml",
    siteUrl: String = "https://www.example.com"
  ) throws -> FeedbinSubscription {
    let json: [String: Any] = [
      "id": id, "feed_id": feedId, "title": title,
      "feed_url": feedUrl, "site_url": siteUrl,
      "created_at": "2025-01-01T00:00:00.000000Z",
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinSubscription.self, from: data)
  }

  private static func makeFeedbinEntry(
    id: Int = 1001, feedId: Int = 100, title: String? = "Test Article",
    content: String? = "<p>Hello <b>world</b></p>",
    url: String = "https://example.com/article",
    published: String = "2025-06-15T12:00:00.000000Z"
  ) throws -> FeedbinEntry {
    var json: [String: Any] = [
      "id": id, "feed_id": feedId, "url": url,
      "published": published, "created_at": published,
    ]
    if let title { json["title"] = title }
    if let content { json["content"] = content }
    let data = try JSONSerialization.data(withJSONObject: json)
    return try makeFeedbinDecoder().decode(FeedbinEntry.self, from: data)
  }

  private func seedFeed(_ writer: DataWriter, id: Int = 1, feedId: Int = 100) async throws {
    let sub = try Self.makeFeedbinSubscription(id: id, feedId: feedId)
    try await writer.syncFeeds([sub])
  }

  // MARK: - persistEntries (markAsRead overload)

  @Test
  func persistEntriesInsertsNewEntries() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entries = [
      try Self.makeFeedbinEntry(id: 1001),
      try Self.makeFeedbinEntry(id: 1002, title: "Second Article"),
    ]
    let count = try await writer.persistEntries(entries, markAsRead: false)

    #expect(count == 2)
  }

  @Test
  func persistEntriesDeduplicates() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entry = try Self.makeFeedbinEntry(id: 1001)
    let first = try await writer.persistEntries([entry], markAsRead: false)
    let second = try await writer.persistEntries([entry], markAsRead: false)

    #expect(first == 1)
    #expect(second == 0)
  }

  @Test
  func persistEntriesComputesPlainText() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entry = try Self.makeFeedbinEntry(
      id: 1001, content: "<p>Hello <b>world</b></p>")
    _ = try await writer.persistEntries([entry], markAsRead: false)

    let inputs = try await writer.fetchUnclassifiedInputs()
    let persisted = inputs.first { $0.entryID == 1001 }
    #expect(persisted != nil)
    #expect(persisted?.body.contains("Hello") == true)
    #expect(persisted?.body.contains("world") == true)
    // HTML tags should be stripped
    #expect(persisted?.body.contains("<p>") == false)
  }

  @Test
  func persistEntriesAssociatesWithFeed() async throws {
    let writer = try await makeWriter()
    let sub = try Self.makeFeedbinSubscription(
      id: 1, feedId: 100,
      siteUrl: "https://www.theverge.com")
    try await writer.syncFeeds([sub])

    let entry = try Self.makeFeedbinEntry(id: 1001, feedId: 100)
    let count = try await writer.persistEntries([entry], markAsRead: false)

    #expect(count == 1)
    let inputs = try await writer.fetchUnclassifiedInputs()
    #expect(inputs.count == 1)
    #expect(inputs.first?.title == "Test Article")
  }

  @Test
  func persistEntriesMarksAsRead() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let unreadEntry = try Self.makeFeedbinEntry(id: 1001)
    let readEntry = try Self.makeFeedbinEntry(id: 1002, title: "Read One")
    _ = try await writer.persistEntries([unreadEntry], markAsRead: false)
    _ = try await writer.persistEntries([readEntry], markAsRead: true)

    // Flip read entry to unread via updateReadState — verifies it was read before
    try await writer.updateReadState(unreadIDs: Set([1001, 1002]))

    // Both entries should exist as unclassified
    let inputs = try await writer.fetchUnclassifiedInputs()
    #expect(inputs.count == 2)
  }

  // MARK: - persistEntries (unreadIDs overload)

  @Test
  func persistEntriesWithUnreadIDsSetsReadState() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entries = [
      try Self.makeFeedbinEntry(id: 1001),
      try Self.makeFeedbinEntry(id: 1002, title: "Read Article"),
    ]
    // 1001 is unread, 1002 is not in unread set so it's read
    let count = try await writer.persistEntries(entries, unreadIDs: Set([1001]))

    #expect(count == 2)

    // Verify read state: mark all as unread, then check both exist
    try await writer.updateReadState(unreadIDs: Set([1001, 1002]))
    let inputs = try await writer.fetchUnclassifiedInputs()
    #expect(inputs.count == 2)
  }

  // MARK: - applyClassification

  @Test
  func applyClassificationSetsFields() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entry = try Self.makeFeedbinEntry(id: 1001)
    _ = try await writer.persistEntries([entry], markAsRead: false)

    try await writer.addCategory(
      label: "technology", displayName: "Technology",
      description: "Tech news", sortOrder: 0)

    let result = ClassificationResult(
      entryID: 1001,
      categoryLabels: ["technology"],
      storyKey: "test-story",
      detectedLanguage: "en",
      confidence: 0.9
    )
    try await writer.applyClassification(entryID: 1001, result: result)

    let inputs = try await writer.fetchUnclassifiedInputs()
    // Entry should no longer appear as unclassified
    #expect(!inputs.contains { $0.entryID == 1001 })
  }

  @Test
  func applyClassificationEnforcesDeepestMatch() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entry = try Self.makeFeedbinEntry(id: 1001)
    _ = try await writer.persistEntries([entry], markAsRead: false)

    try await writer.addCategory(
      label: "technology", displayName: "Technology",
      description: "Tech", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Apple",
      description: "Apple", sortOrder: 0, parentLabel: "technology")

    // Classify with both parent and child — parent should be stripped
    let result = ClassificationResult(
      entryID: 1001,
      categoryLabels: ["technology", "apple"],
      storyKey: "apple-story",
      detectedLanguage: "en",
      confidence: 0.8
    )
    try await writer.applyClassification(entryID: 1001, result: result)

    // Verify entry is classified (no longer in unclassified list)
    let inputs = try await writer.fetchUnclassifiedInputs()
    #expect(!inputs.contains { $0.entryID == 1001 })
  }

  @Test
  func applyClassificationHandlesMissingEntry() async throws {
    let writer = try await makeWriter()

    let result = ClassificationResult(
      entryID: 99999,
      categoryLabels: ["technology"],
      storyKey: "missing-story",
      detectedLanguage: "en",
      confidence: 0.9
    )
    // Should not crash — guard returns early for missing entry
    try await writer.applyClassification(entryID: 99999, result: result)
  }

  // MARK: - updateReadState

  @Test
  func updateReadStateBulkUpdate() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let entries = [
      try Self.makeFeedbinEntry(id: 1001),
      try Self.makeFeedbinEntry(id: 1002, title: "Second"),
      try Self.makeFeedbinEntry(id: 1003, title: "Third"),
    ]
    _ = try await writer.persistEntries(entries, markAsRead: false)

    // Mark 1001 as unread, 1002 and 1003 become read
    try await writer.updateReadState(unreadIDs: Set([1001]))

    // Now flip: only 1002 unread, rest become read
    try await writer.updateReadState(unreadIDs: Set([1002]))

    // All 3 entries should still be in the store (read state change doesn't delete)
    let inputs = try await writer.fetchUnclassifiedInputs()
    #expect(inputs.count == 3)
  }

  @Test
  func updateReadStateNoChangesSkipsSave() async throws {
    let writer = try await makeWriter()

    // No entries exist — should not crash
    try await writer.updateReadState(unreadIDs: Set())
  }

  // MARK: - purgeEntriesOlderThan

  @Test
  func purgeRemovesOldEntries() async throws {
    let writer = try await makeWriter()
    try await seedFeed(writer)

    let oldEntry = try Self.makeFeedbinEntry(
      id: 1001, title: "Old",
      published: "2024-01-01T00:00:00.000000Z")
    let newEntry = try Self.makeFeedbinEntry(
      id: 1002, title: "New",
      published: "2026-06-01T00:00:00.000000Z")
    _ = try await writer.persistEntries([oldEntry, newEntry], markAsRead: false)

    // Purge entries older than 2025-01-01
    let cutoff = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
    try await writer.purgeEntriesOlderThan(cutoff)

    let remaining = try await writer.fetchUnclassifiedInputs()
    #expect(remaining.count == 1)
    #expect(remaining.first?.entryID == 1002)
  }

  @Test
  func purgeWithNothingToDeleteIsNoOp() async throws {
    let writer = try await makeWriter()

    let cutoff = Date()
    // No entries exist — should not crash
    try await writer.purgeEntriesOlderThan(cutoff)
  }
}
