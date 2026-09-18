import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of the
/// store, and it has two legitimate paths:
///
/// - The seeded flag is absent, so it seeds the defaults.
/// - The seeded flag is present, so it skips, even when the user has deleted
///   default categories.
///
/// Schema migration runs inside the container open, so the data-loss guarantees
/// belong to `FeederMigrationPlanTests`, not here.
@Suite("DataWriter.bootstrap")
struct DataWriterBootstrapTests {
  // MARK: - Seeded

  @Test
  func seedsDefaultTaxonomyOnEmptyStore() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()

    let outcome = try await writer.bootstrap()

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

    _ = try await writer.bootstrap()

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  /// The seeded-defaults sentinel must be written exactly once. A second
  /// `bootstrap()` call against the same flag store must see the flag and
  /// short-circuit without re-inserting defaults.
  @Test
  func firstSeedSetsTheSentinelFlag() async throws {
    let flagStore = InMemoryFlagStore()
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: flagStore)

    #expect(flagStore.isSeeded(forKey: defaultsSeededUserDefaultsKey) == false)
    _ = try await writer.bootstrap()
    #expect(flagStore.isSeeded(forKey: defaultsSeededUserDefaultsKey) == true)
  }

  // MARK: - Skipped / steady state

  /// Two bootstraps against the same store: the second must be a no-op.
  /// Guards against accidentally re-seeding defaults on every launch,
  /// which would duplicate folders/categories or trample user edits.
  @Test
  func steadyStateSkipsWhenSentinelPresent() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()

    _ = try await writer.bootstrap()
    let outcome = try await writer.bootstrap()

    #expect(outcome.action == .skipped)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
  }

  /// User-created taxonomy must survive across bootstraps. This is the
  /// vision-aligned outcome the migration framework protects: folders,
  /// categories, and classifications persist across launches.
  @Test
  func steadyStatePreservesUserCreatedFoldersAndCategories() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()

    _ = try await writer.bootstrap()
    try await writer.addFolder(label: "user_made_folder", displayName: "User", sortOrder: 100)
    try await writer.addCategory(
      label: "user_made_category", displayName: "User Cat",
      description: "Should survive bootstrap.", sortOrder: 100, folderLabel: "user_made_folder"
    )

    let outcome = try await writer.bootstrap()

    #expect(outcome.action == .skipped)
    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == "user_made_category" })
    #expect(outcome.folderCount == DefaultCategoryData.folders.count + 1)
  }

  /// A user who deletes every default category must not see them re-seeded on
  /// the next launch: the sentinel makes bootstrap respect an explicit
  /// taxonomy reset.
  @Test
  func emptyCategoriesAfterSeedDoesNotReSeed() async throws {
    let flagStore = InMemoryFlagStore()
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: flagStore)

    _ = try await writer.bootstrap()

    // Delete every default category, including the system fallback, the way a
    // deliberate taxonomy reset would.
    let initialDefs = try await writer.fetchCategoryDefinitions()
    for def in initialDefs {
      try await writer.updateSystemFlag(label: def.label, isSystem: false)
      try await writer.deleteCategory(label: def.label)
    }

    let outcome = try await writer.bootstrap()
    #expect(outcome.action == .skipped)
    #expect(outcome.categoryCount == 0)
  }

  /// The upgrade path: an install has a populated taxonomy on disk but no
  /// seeded flag, because the sentinel did not exist when it was written.
  /// Bootstrap must not re-seed there, or the unique-label upsert overwrites
  /// every customised field on a default-labelled row.
  ///
  /// With the flag absent and the categories table non-empty, treat it as
  /// already seeded, set
  /// the flag, and skip the seed path entirely. Subsequent launches see
  /// the flag set and short-circuit through the steady-state path.
  @Test
  func bootstrapDoesNotReSeedWhenSentinelIsAbsentButTaxonomyExists() async throws {
    let flagStore = InMemoryFlagStore()
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: flagStore)

    // Manually populate the store as if a pre-sentinel install had
    // already seeded + customised the taxonomy. Add a custom folder, a
    // user-edited default category, and a freshly-named user category so
    // we can prove every kind of pre-existing data survives.
    try await writer.addFolder(label: "technology", displayName: "Custom Tech", sortOrder: 0)
    try await writer.addCategory(
      label: "apple", displayName: "Custom Apple", description: "Custom desc.",
      sortOrder: 5, folderLabel: "technology"
    )

    let outcome = try await writer.bootstrap()

    #expect(outcome.action == .skipped)
    #expect(flagStore.isSeeded(forKey: defaultsSeededUserDefaultsKey) == true)
    let defs = try await writer.fetchCategoryDefinitions()
    let apple = defs.first { $0.label == "apple" }
    // Customised fields survive — the bootstrap did not overwrite them
    // via a default-data upsert.
    #expect(apple?.description == "Custom desc.")
    #expect(apple?.folderLabel == "technology")
    // Total category count matches what we wrote, with no defaults
    // re-seeded on top.
    #expect(outcome.categoryCount == 1)
    #expect(outcome.folderCount == 1)
  }

  /// A user who customises a default category must not see those edits reverted
  /// by a later bootstrap: the first seed is authoritative, and no later
  /// bootstrap writes to the taxonomy.
  @Test
  func customisedCategoryEditsSurviveSubsequentBootstrap() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()

    _ = try await writer.bootstrap()
    let initialDefs = try await writer.fetchCategoryDefinitions()
    guard let firstDefault = initialDefs.first(where: { $0.label != uncategorizedLabel })
    else {
      Issue.record("Expected at least one seeded default category")
      return
    }

    try await writer.updateCategoryFields(
      label: firstDefault.label,
      displayName: "User-renamed",
      description: "User-edited description that must survive bootstrap."
    )

    let outcome = try await writer.bootstrap()
    #expect(outcome.action == .skipped)

    let postDefs = try await writer.fetchCategoryDefinitions()
    let edited = postDefs.first { $0.label == firstDefault.label }
    #expect(edited?.description == "User-edited description that must survive bootstrap.")
  }
}
