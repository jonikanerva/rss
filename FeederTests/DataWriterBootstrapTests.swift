import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of
/// the persistent store. Two legitimate startup paths exist now that
/// schema migration runs inside the `ModelContainer` open
/// (`FeederMigrationPlan`):
///
/// - Categories table empty → seed defaults → `.seeded` (first launch).
/// - Categories table populated → `.skipped` (steady state).
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

  // MARK: - Skipped / steady state

  /// Two bootstraps against the same store: the second must be a no-op.
  /// Guards against accidentally re-seeding defaults on every launch,
  /// which would duplicate folders/categories or trample user edits.
  @Test
  func steadyStateSkipsWhenCategoriesPresent() async throws {
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
}
