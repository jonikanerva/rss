import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of
/// the persistent store. Each scenario (steady state, first-launch seed,
/// schema bump reset) is exercised against the real `UserDefaults.standard`
/// because that is what production reads. The suite is serialized so the
/// shared schema-version key isn't trampled between test cases that all
/// touch the same standard defaults domain.
@Suite("DataWriter.bootstrap", .serialized)
struct DataWriterBootstrapTests {
  /// Source the key from production so the test breaks if the key string
  /// changes — no magic-string duplication here.
  private static let schemaVersionKey = DataWriter.schemaVersionKey

  /// Returns a random schema-version value for each test invocation so a
  /// single test's intermediate writes can't accidentally match a value
  /// another test left behind in `UserDefaults`.
  private static func makeIsolatedSchemaVersion() -> Int {
    Int.random(in: 1_000_000...9_999_999)
  }

  // MARK: - Skipped / steady state

  @Test
  func steadyStateSkipsWhenCategoriesPresentAndVersionMatches() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)
    defer { UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey) }

    // First bootstrap seeds defaults.
    _ = try await writer.bootstrap(currentSchemaVersion: version)
    // Second bootstrap on the same store + same version should be a no-op.
    let outcome = try await writer.bootstrap(currentSchemaVersion: version)

    #expect(outcome.action == .skipped)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
  }

  // MARK: - Seeded

  @Test
  func seedsDefaultsWhenStoreEmptyButVersionMatches() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    // "Store is empty but version key already matches" — e.g. the
    // store was opened, version persisted, then categories cleared manually.
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)
    defer { UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey) }

    let outcome = try await writer.bootstrap(currentSchemaVersion: version)

    #expect(outcome.action == .seeded)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    // +1 for the system uncategorized fallback.
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
    #expect(outcome.entryCount == 0)
    #expect(outcome.feedCount == 0)
  }

  @Test
  func bootstrapInsertsUncategorizedAsSystemCategory() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)
    defer { UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey) }

    _ = try await writer.bootstrap(currentSchemaVersion: version)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  // MARK: - Reset

  /// Real first-launch path: nothing in `UserDefaults`, so the
  /// integer read returns 0 and bootstrap must take the `.reset` branch.
  /// Guards against accidentally treating a missing key as "version matches".
  @Test
  func firstLaunchWithEmptyVersionHitsResetPath() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
    defer { UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey) }

    let outcome = try await writer.bootstrap(currentSchemaVersion: Self.makeIsolatedSchemaVersion())

    if case .reset = outcome.action {
      // Expected — first launch on an empty store still goes through the
      // reset path because the missing version key reads as 0.
    } else {
      Issue.record("Expected .reset for empty version key, got \(outcome.action)")
    }
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
  }

  /// Critical safety test: seed real entries / feeds / non-system
  /// categories, then trigger a schema bump and verify every table is
  /// wiped plus defaults are re-seeded. Catches regressions like a missing
  /// `delete(model: Feed.self)` line that the previous version of this
  /// suite let through.
  @Test
  func schemaVersionBumpWipesEverythingAndReseeds() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let oldVersion = Self.makeIsolatedSchemaVersion()
    let newVersion = oldVersion + 1
    UserDefaults.standard.set(oldVersion, forKey: Self.schemaVersionKey)
    UserDefaults.standard.set(Date(), forKey: lastSyncDateUserDefaultsKey)
    defer {
      UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
      UserDefaults.standard.removeObject(forKey: lastSyncDateUserDefaultsKey)
    }

    // Seed real data the reset must wipe.
    let subscription = try Self.makeFeedbinSubscription(id: 1, feedId: 100)
    try await writer.syncFeeds([subscription])
    let entries = [
      try Self.makeFeedbinEntry(id: 5001, feedId: 100),
      try Self.makeFeedbinEntry(id: 5002, feedId: 100),
      try Self.makeFeedbinEntry(id: 5003, feedId: 100),
    ]
    let inserted = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))
    #expect(inserted == 3)

    try await writer.addFolder(label: "preexisting", displayName: "Preexisting", sortOrder: 0)
    try await writer.addCategory(
      label: "user_made", displayName: "User Made", description: "kept across reset?",
      sortOrder: 0, folderLabel: "preexisting"
    )

    // Bump version → wipe everything + reseed defaults.
    let outcome = try await writer.bootstrap(currentSchemaVersion: newVersion)

    if case .reset(let deletedEntries) = outcome.action {
      #expect(deletedEntries == 3)
    } else {
      Issue.record("Expected .reset action, got \(outcome.action)")
    }
    #expect(outcome.entryCount == 0)
    #expect(outcome.feedCount == 0)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
    // User-made category must be gone after reset.
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(!defs.contains { $0.label == "user_made" })
    // lastSyncDate is cleared on reset so the next sync re-fetches fresh.
    #expect(UserDefaults.standard.object(forKey: lastSyncDateUserDefaultsKey) == nil)
    #expect(UserDefaults.standard.integer(forKey: Self.schemaVersionKey) == newVersion)
  }

  // MARK: - Test fixtures

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
    id: Int = 5001, feedId: Int = 100, title: String? = "Test Article",
    content: String? = "<p>Hello world</p>",
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
}
