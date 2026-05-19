import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Migration framework tests. These guard the contract that user data
/// (folders, categories with display name + description + keywords +
/// sortOrder, classified entries with `primaryCategory` / `primaryFolder`,
/// feeds) survives a `ModelContainer` open. V1 has no predecessor, so
/// the scenarios here cover the shape of the plan and the round-trip
/// path: open → write → close → open with the plan → all rows visible.
@Suite("FeederMigrationPlan")
struct FeederMigrationPlanTests {
  // MARK: - Plan shape

  @Test
  func planAdvertisesV1AsTheOnlySchemaVersion() {
    let schemaIDs = FeederMigrationPlan.schemas.map { ObjectIdentifier($0) }
    #expect(schemaIDs == [ObjectIdentifier(FeederSchemaV1.self)])
  }

  @Test
  func planHasNoStagesYet() {
    // V1 is the inception version: there is nothing to migrate from.
    // The next schema bump adds an entry here; the assertion forces a
    // conscious update at the same time `schemas` grows.
    #expect(FeederMigrationPlan.stages.isEmpty)
  }

  @Test
  func v1SchemaListsAllModels() {
    let modelIDs = FeederSchemaV1.models.map { ObjectIdentifier($0) }
    let expected: [ObjectIdentifier] = [
      ObjectIdentifier(Feed.self),
      ObjectIdentifier(Entry.self),
      ObjectIdentifier(Feeder.Category.self),
      ObjectIdentifier(Folder.self),
    ]
    // Order-independent set comparison — the migration plan does not
    // depend on the array order, only membership.
    #expect(Set(modelIDs) == Set(expected))
  }

  @Test
  func v1VersionIdentifierIsOneZeroZero() {
    #expect(FeederSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
  }

  // MARK: - In-memory round-trip

  /// Open a fresh `ModelContainer` against the migration plan, insert one
  /// of each `@Model` type, and read everything back. Guards against
  /// regressions where the plan references a model type that does not
  /// compile against the live schema (e.g. a rename that was not
  /// reflected in the typealias).
  @Test
  @MainActor
  func roundTripsAllModelsThroughTheMigrationPlanInMemory() throws {
    let schema = Schema(versionedSchema: FeederSchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: configuration
    )
    let context = ModelContext(container)

    let folder = Folder(label: "test_folder", displayName: "Test Folder", sortOrder: 0)
    let category = Feeder.Category(
      label: "test_cat", displayName: "Test Cat", categoryDescription: "desc",
      sortOrder: 0, folderLabel: "test_folder", keywords: ["alpha", "beta"]
    )
    let feed = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 100,
      title: "Test Feed", feedURL: "https://example.com/feed",
      siteURL: "https://example.com", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let entry = Entry(
      feedbinEntryID: 999, title: "Title", author: "Author", url: "https://example.com/post",
      content: nil, summary: nil, extractedContentURL: nil,
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    context.insert(folder)
    context.insert(category)
    context.insert(feed)
    context.insert(entry)
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<Folder>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<Feeder.Category>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<Feed>()) == 1)
    #expect(try context.fetchCount(FetchDescriptor<Entry>()) == 1)
  }

  // MARK: - On-disk round-trip (V1 → V1)

  /// Critical end-to-end migration safety test: write a populated v1
  /// store to disk, close the container, open a fresh one with the
  /// migration plan against the same URL, and verify every row survives.
  /// This is the regression guard for the issue that motivated the
  /// migration framework — the old `currentSchemaVersion` mismatch path
  /// would have wiped the store; the migration plan must not.
  @Test
  @MainActor
  func reopeningOnDiskStorePreservesUserData() throws {
    let storeURL = Self.makeTemporaryStoreURL()
    defer { Self.cleanUpStoreFiles(at: storeURL) }

    // Pass 1: open the store, populate it, drop the container.
    try Self.writePopulatedStore(at: storeURL)

    // Pass 2: open with the migration plan — V1 → V1, no stage runs,
    // but the open exercises the plan resolution path.
    let schema = Schema(versionedSchema: FeederSchemaV1.self)
    let reopenConfig = ModelConfiguration(schema: schema, url: storeURL)
    let reopened = try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: reopenConfig
    )
    let context = ModelContext(reopened)

    let folders = try context.fetch(FetchDescriptor<Folder>())
    let categories = try context.fetch(FetchDescriptor<Feeder.Category>())
    let feeds = try context.fetch(FetchDescriptor<Feed>())
    let entries = try context.fetch(FetchDescriptor<Entry>())

    #expect(folders.count == 1)
    #expect(folders.first?.displayName == "Persisted Folder")
    #expect(categories.count == 1)
    #expect(categories.first?.label == "persisted_cat")
    #expect(categories.first?.keywords == ["keyword-one", "keyword-two"])
    #expect(feeds.count == 1)
    #expect(feeds.first?.title == "Persisted Feed")
    #expect(entries.count == 1)
    // Verify denormalized classification fields survive — these are the
    // "local-only state" the issue called out as previously lost on
    // schema bump.
    #expect(entries.first?.primaryCategory == "persisted_cat")
    #expect(entries.first?.primaryFolder == "persisted_folder")
    #expect(entries.first?.isClassified == true)
  }

  // MARK: - Helpers

  /// Write a V1 store with one folder, one category, one feed, one
  /// classified entry, then drop the container. Encapsulated so the
  /// container goes out of scope before the reopened test container
  /// touches the same URL.
  @MainActor
  private static func writePopulatedStore(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: FeederSchemaV1.self)
    let config = ModelConfiguration(schema: schema, url: storeURL)
    let container = try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: config
    )
    let context = ModelContext(container)
    let folder = Folder(label: "persisted_folder", displayName: "Persisted Folder", sortOrder: 0)
    let category = Feeder.Category(
      label: "persisted_cat", displayName: "Persisted", categoryDescription: "Persisted desc.",
      sortOrder: 0, folderLabel: "persisted_folder", keywords: ["keyword-one", "keyword-two"]
    )
    let feed = Feed(
      feedbinSubscriptionID: 7, feedbinFeedID: 700,
      title: "Persisted Feed", feedURL: "https://example.com/feed",
      siteURL: "https://example.com", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let entry = Entry(
      feedbinEntryID: 12_345, title: "Persisted Entry", author: nil,
      url: "https://example.com/post", content: nil, summary: nil,
      extractedContentURL: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    entry.feed = feed
    entry.isClassified = true
    entry.primaryCategory = "persisted_cat"
    entry.primaryFolder = "persisted_folder"
    context.insert(folder)
    context.insert(category)
    context.insert(feed)
    context.insert(entry)
    try context.save()
  }

  /// Build a unique on-disk store URL inside the per-process temp dir
  /// so parallel test invocations cannot collide.
  private static func makeTemporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("feeder.migration.\(UUID().uuidString)")
      .appendingPathExtension("store")
  }

  /// Remove the SwiftData store file plus its WAL/SHM siblings.
  private static func cleanUpStoreFiles(at storeURL: URL) {
    for suffix in ["", "-shm", "-wal"] {
      let url = storeURL.appendingPathExtension(suffix)
      try? FileManager.default.removeItem(at: url)
    }
    try? FileManager.default.removeItem(at: storeURL)
  }
}
