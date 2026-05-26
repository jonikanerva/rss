import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of
/// the persistent store. Two legitimate startup paths exist now that
/// schema migration runs inside the `ModelContainer` open
/// (`FeederMigrationPlan`):
///
/// - Defaults-seeded flag absent → seed defaults → `.seeded` (first launch).
/// - Defaults-seeded flag present → `.skipped` (steady state), even if the
///   user has deleted some or all default categories.
///
/// The pre-migration version of this suite asserted the destructive
/// "schema version bump wipes everything" path; that path is gone because
/// schema changes now migrate the store rather than recreate it. The
/// data-loss safety guarantees those old tests defended are now covered
/// by `FeederMigrationPlanTests`.
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

  /// Issue #87 acceptance: a user who deletes every default category does
  /// NOT see them re-seeded on next launch. The old table-empty bootstrap
  /// would have silently re-inserted the defaults, trampling a deliberate
  /// taxonomy reset. The sentinel-based bootstrap respects the user's
  /// explicit deletions.
  @Test
  func emptyCategoriesAfterSeedDoesNotReSeed() async throws {
    let flagStore = InMemoryFlagStore()
    let container = try DataWriterTestSupport.makeInMemoryContainer()
    let writer = DataWriter(modelContainer: container, defaultsFlagStore: flagStore)

    _ = try await writer.bootstrap()

    // Simulate the user deleting every default category — including the
    // system uncategorized fallback — through manual SQL or a future
    // settings-pane "reset taxonomy" action.
    let initialDefs = try await writer.fetchCategoryDefinitions()
    for def in initialDefs {
      try await writer.updateSystemFlag(label: def.label, isSystem: false)
      try await writer.deleteCategory(label: def.label)
    }

    let outcome = try await writer.bootstrap()
    #expect(outcome.action == .skipped)
    #expect(outcome.categoryCount == 0)
  }

  /// Issue #87 acceptance: a user who customises a default category
  /// (rename, description, keyword edit) does NOT see those edits reverted
  /// by a subsequent bootstrap. The sentinel makes the first seed
  /// authoritative; subsequent bootstraps never write to the taxonomy.
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
