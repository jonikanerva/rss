import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Migration framework tests. These guard the contract that user data
/// (folders, categories with display name + description + keywords +
/// sortOrder, classified entries with `primaryCategory` / `primaryFolder`,
/// feeds) survives a `ModelContainer` open. V1→V2 drops the dead
/// `Entry.detectedLanguage` column and V2→V3 drops the unread
/// `Entry.formattedDate` column, both via lightweight stages; the suite
/// asserts both the plan shape and the on-disk round-trip across the
/// stages.
@Suite("FeederMigrationPlan")
struct FeederMigrationPlanTests {
  // MARK: - Plan shape

  @Test
  func planAdvertisesV1V2AndV3InOrder() {
    let schemaIDs = FeederMigrationPlan.schemas.map { ObjectIdentifier($0) }
    #expect(
      schemaIDs == [
        ObjectIdentifier(FeederSchemaV1.self),
        ObjectIdentifier(FeederSchemaV2.self),
        ObjectIdentifier(FeederSchemaV3.self),
      ]
    )
  }

  @Test
  func planHasOneLightweightStagePerAdjacentPair() {
    // V1→V2 drops `Entry.detectedLanguage` and V2→V3 drops
    // `Entry.formattedDate`. No `.custom` stage is needed because neither
    // field is an input to another denormalized display field — see
    // `STACK.md` § 5.
    #expect(FeederMigrationPlan.stages.count == 2)
  }

  @Test
  func v1SchemaListsAllModels() {
    let modelIDs = FeederSchemaV1.models.map { ObjectIdentifier($0) }
    let expected: [ObjectIdentifier] = [
      ObjectIdentifier(FeederSchemaV1.Feed.self),
      ObjectIdentifier(FeederSchemaV1.Entry.self),
      ObjectIdentifier(FeederSchemaV1.Category.self),
      ObjectIdentifier(FeederSchemaV1.Folder.self),
    ]
    #expect(Set(modelIDs) == Set(expected))
  }

  @Test
  func v2SchemaListsAllModels() {
    let modelIDs = FeederSchemaV2.models.map { ObjectIdentifier($0) }
    let expected: [ObjectIdentifier] = [
      ObjectIdentifier(FeederSchemaV2.Feed.self),
      ObjectIdentifier(FeederSchemaV2.Entry.self),
      ObjectIdentifier(FeederSchemaV2.Category.self),
      ObjectIdentifier(FeederSchemaV2.Folder.self),
    ]
    #expect(Set(modelIDs) == Set(expected))
  }

  @Test
  func v3SchemaListsAllModels() {
    let modelIDs = FeederSchemaV3.models.map { ObjectIdentifier($0) }
    let expected: [ObjectIdentifier] = [
      ObjectIdentifier(FeederSchemaV3.Feed.self),
      ObjectIdentifier(FeederSchemaV3.Entry.self),
      ObjectIdentifier(FeederSchemaV3.Category.self),
      ObjectIdentifier(FeederSchemaV3.Folder.self),
    ]
    #expect(Set(modelIDs) == Set(expected))
  }

  @Test
  func v1VersionIdentifierIsOneZeroZero() {
    #expect(FeederSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
  }

  @Test
  func v2VersionIdentifierIsTwoZeroZero() {
    #expect(FeederSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
  }

  @Test
  func v3VersionIdentifierIsThreeZeroZero() {
    #expect(FeederSchemaV3.versionIdentifier == Schema.Version(3, 0, 0))
  }

  // MARK: - In-memory round-trip

  /// Open a fresh `ModelContainer` against the V3 schema + migration
  /// plan, insert one of each `@Model` type, and read everything back.
  /// Guards against regressions where the plan references a model type
  /// that does not compile against the live schema (e.g. a rename that
  /// was not reflected in the typealias).
  @Test
  @MainActor
  func roundTripsAllModelsThroughTheMigrationPlanInMemory() throws {
    let schema = Schema(versionedSchema: FeederSchemaV3.self)
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

  // MARK: - On-disk round-trip

  /// End-to-end migration safety: write a populated V1 store to disk, close the
  /// container, open a fresh one with the migration plan and the V3 schema
  /// against the same URL, and verify every row survives both stages. A
  /// user-customised category must come through unchanged.
  @Test
  @MainActor
  func migratingV1StoreToV3PreservesUserData() throws {
    let folder = try Self.makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let storeURL = folder.appending(path: "Feeder.store")

    try Self.writePopulatedV1Store(at: storeURL)

    try Self.expectUserDataSurvives(at: storeURL)
  }

  /// A V2 store, the shape of every install before V3, opens as V3 through
  /// the lightweight V2→V3 stage. Only `formattedDate` goes away.
  @Test
  @MainActor
  func migratingV2StoreToV3PreservesUserData() throws {
    let folder = try Self.makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let storeURL = folder.appending(path: "Feeder.store")

    try Self.writePopulatedV2Store(at: storeURL)

    try Self.expectUserDataSurvives(at: storeURL)
  }

  // MARK: - Helpers

  /// Open the store at `storeURL` with the V3 schema and the migration plan,
  /// and check that every row and every kept display field survives.
  @MainActor
  private static func expectUserDataSurvives(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: FeederSchemaV3.self)
    let reopened = try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: ModelConfiguration(schema: schema, url: storeURL)
    )
    let context = ModelContext(reopened)

    let folders = try context.fetch(FetchDescriptor<Folder>())
    let categories = try context.fetch(FetchDescriptor<Feeder.Category>())
    let feeds = try context.fetch(FetchDescriptor<Feed>())
    let entries = try context.fetch(FetchDescriptor<Entry>())

    #expect(folders.count == 1)
    #expect(folders.first?.displayName == "Persisted Folder")
    #expect(folders.first?.sortOrder == 0)
    #expect(categories.count == 1)
    let cat = categories.first
    #expect(cat?.label == "persisted_cat")
    #expect(cat?.displayName == "Persisted")
    #expect(cat?.categoryDescription == "Persisted desc.")
    #expect(cat?.keywords == ["keyword-one", "keyword-two"])
    #expect(cat?.sortOrder == 0)
    // `folderLabel` is a plain `String?`, not a relationship, so a stage
    // could drop it without an error, and the sidebar grouping would
    // collapse to root level.
    #expect(cat?.folderLabel == "persisted_folder")

    #expect(feeds.count == 1)
    #expect(feeds.first?.title == "Persisted Feed")

    #expect(entries.count == 1)
    let entry = entries.first
    #expect(entry?.primaryCategory == "persisted_cat")
    #expect(entry?.primaryFolder == "persisted_folder")
    #expect(entry?.isClassified == true)
    #expect(entry?.plainText == "persisted plain text")
    #expect(entry?.formattedPublishedTime == "21.24")
    #expect(entry?.displayDomain == "example.com")
    #expect(entry?.summaryPlainText == "persisted summary")
    #expect(entry?.articleBlocksData != nil)
  }

  /// Write a V2 store with the same rows as `writePopulatedV1Store`, with
  /// `formattedDate` set, so the V2→V3 stage has a value to drop.
  @MainActor
  private static func writePopulatedV2Store(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
    let context = ModelContext(container)

    let feed = FeederSchemaV2.Feed(
      feedbinSubscriptionID: 7, feedbinFeedID: 700,
      title: "Persisted Feed", feedURL: "https://example.com/feed",
      siteURL: "https://example.com", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let entry = FeederSchemaV2.Entry(
      feedbinEntryID: 12_345, title: "Persisted Entry", author: nil,
      url: "https://example.com/post", content: nil, summary: nil,
      extractedContentURL: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    entry.feed = feed
    entry.isClassified = true
    entry.primaryCategory = "persisted_cat"
    entry.primaryFolder = "persisted_folder"
    entry.plainText = "persisted plain text"
    entry.formattedDate = "Persisted, 5th Mar"
    entry.formattedPublishedTime = "21.24"
    entry.displayDomain = "example.com"
    entry.summaryPlainText = "persisted summary"
    entry.articleBlocksData = Data("[]".utf8)
    context.insert(
      FeederSchemaV2.Folder(label: "persisted_folder", displayName: "Persisted Folder", sortOrder: 0))
    context.insert(
      FeederSchemaV2.Category(
        label: "persisted_cat", displayName: "Persisted", categoryDescription: "Persisted desc.",
        sortOrder: 0, folderLabel: "persisted_folder", keywords: ["keyword-one", "keyword-two"]
      ))
    context.insert(feed)
    context.insert(entry)
    try context.save()
  }

  /// Write a V1 store with one folder, one category, one feed, one
  /// classified entry (with `detectedLanguage` populated). Encapsulated
  /// so the container goes out of scope before the reopened test
  /// container touches the same URL.
  @MainActor
  private static func writePopulatedV1Store(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: FeederSchemaV1.self)
    let config = ModelConfiguration(schema: schema, url: storeURL)
    // V1 store opens against V1 schema with no migration plan — this is
    // the snapshot a user with a pre-V2 install has on disk.
    let container = try ModelContainer(for: schema, configurations: config)
    let context = ModelContext(container)

    let folder = FeederSchemaV1.Folder(
      label: "persisted_folder", displayName: "Persisted Folder", sortOrder: 0
    )
    let category = FeederSchemaV1.Category(
      label: "persisted_cat", displayName: "Persisted", categoryDescription: "Persisted desc.",
      sortOrder: 0, folderLabel: "persisted_folder", keywords: ["keyword-one", "keyword-two"]
    )
    let feed = FeederSchemaV1.Feed(
      feedbinSubscriptionID: 7, feedbinFeedID: 700,
      title: "Persisted Feed", feedURL: "https://example.com/feed",
      siteURL: "https://example.com", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let entry = FeederSchemaV1.Entry(
      feedbinEntryID: 12_345, title: "Persisted Entry", author: nil,
      url: "https://example.com/post", content: nil, summary: nil,
      extractedContentURL: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    entry.feed = feed
    entry.isClassified = true
    entry.primaryCategory = "persisted_cat"
    entry.primaryFolder = "persisted_folder"
    entry.plainText = "persisted plain text"
    entry.formattedDate = "Persisted, 5th Mar"
    entry.formattedPublishedTime = "21.24"
    entry.displayDomain = "example.com"
    entry.summaryPlainText = "persisted summary"
    entry.articleBlocksData = Data("[]".utf8)
    // Set the V1-only column so we can verify the lightweight stage
    // drops it cleanly — the entry's classified state must survive
    // even though this property is going away.
    entry.detectedLanguage = "en"
    context.insert(folder)
    context.insert(category)
    context.insert(feed)
    context.insert(entry)
    try context.save()
  }

  /// A unique folder inside the per-process temp dir, so parallel test
  /// invocations cannot collide and one removal deletes the store with its
  /// WAL and SHM files.
  private static func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "FeederMigration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }
}
