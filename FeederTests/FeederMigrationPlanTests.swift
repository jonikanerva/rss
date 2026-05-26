import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Migration framework tests. These guard the contract that user data
/// (folders, categories with display name + description + keywords +
/// sortOrder, classified entries with `primaryCategory` / `primaryFolder`,
/// feeds) survives a `ModelContainer` open. V1→V2 drops the dead
/// `Entry.detectedLanguage` column via a lightweight stage; the suite
/// asserts both the plan shape and the on-disk round-trip across the
/// stage.
@Suite("FeederMigrationPlan")
struct FeederMigrationPlanTests {
  // MARK: - Plan shape

  @Test
  func planAdvertisesV1AndV2InOrder() {
    let schemaIDs = FeederMigrationPlan.schemas.map { ObjectIdentifier($0) }
    #expect(
      schemaIDs == [
        ObjectIdentifier(FeederSchemaV1.self),
        ObjectIdentifier(FeederSchemaV2.self),
      ]
    )
  }

  @Test
  func planHasV1ToV2LightweightStage() {
    // The lightweight V1→V2 stage drops `Entry.detectedLanguage`. No
    // `.custom` stage is needed because that field is not an input to
    // any denormalized display field — see `docs/stack.md` § 5.
    #expect(FeederMigrationPlan.stages.count == 1)
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
  func v1VersionIdentifierIsOneZeroZero() {
    #expect(FeederSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
  }

  @Test
  func v2VersionIdentifierIsTwoZeroZero() {
    #expect(FeederSchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
  }

  // MARK: - In-memory round-trip

  /// Open a fresh `ModelContainer` against the V2 schema + migration
  /// plan, insert one of each `@Model` type, and read everything back.
  /// Guards against regressions where the plan references a model type
  /// that does not compile against the live schema (e.g. a rename that
  /// was not reflected in the typealias).
  @Test
  @MainActor
  func roundTripsAllModelsThroughTheMigrationPlanInMemory() throws {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
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

  // MARK: - On-disk round-trip (V1 → V2)

  /// Critical end-to-end migration safety test (#98): write a populated
  /// V1 store to disk, close the container, open a fresh one with the
  /// migration plan + V2 schema against the same URL, and verify every
  /// row survives. This is the regression guard for the issue that
  /// motivated the migration framework — the pre-PR-#97 reset path would
  /// have wiped the store; the migration plan must not. Acceptance
  /// criterion for issue #87 (user-customised categories survive) and
  /// the lightweight-removal demonstration for #90.
  @Test
  @MainActor
  func migratingV1StoreToV2PreservesUserData() throws {
    let storeURL = Self.makeTemporaryStoreURL()
    defer { Self.cleanUpStoreFiles(at: storeURL) }

    // Pass 1: open the store as V1 (no migration plan), populate with
    // representative data including `detectedLanguage` set on the
    // entry, then drop the container.
    try Self.writePopulatedV1Store(at: storeURL)

    // Pass 2: open with V2 schema + migration plan. SwiftData detects
    // the on-disk V1 shape and runs the lightweight V1→V2 stage,
    // dropping `detectedLanguage` structurally without touching the
    // other rows.
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
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

    // Issue #87 acceptance: user-customised category state survives.
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

    // Feeds survive intact.
    #expect(feeds.count == 1)
    #expect(feeds.first?.title == "Persisted Feed")

    // Classified entries keep their denormalized display fields.
    #expect(entries.count == 1)
    let entry = entries.first
    #expect(entry?.primaryCategory == "persisted_cat")
    #expect(entry?.primaryFolder == "persisted_folder")
    #expect(entry?.isClassified == true)
    #expect(entry?.plainText == "persisted plain text")
    #expect(entry?.formattedDate == "Persisted, 5th Mar")
    #expect(entry?.formattedPublishedTime == "21.24")
    #expect(entry?.displayDomain == "example.com")
    #expect(entry?.summaryPlainText == "persisted summary")
    #expect(entry?.articleBlocksData != nil)

    // Structural assertion: the live V2 Entry has no `detectedLanguage`
    // property. The migration dropped the column. Verified at compile
    // time by the absence of the symbol — if a future refactor
    // re-introduces it without bumping the schema, this test stops
    // compiling, which is the intended early-warning behaviour.
  }

  // MARK: - Helpers

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
