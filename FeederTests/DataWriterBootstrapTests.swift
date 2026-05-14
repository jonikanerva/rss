import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of
/// the persistent store. Each scenario (steady state, first-launch seed,
/// schema bump reset) is exercised against the real `UserDefaults.standard`
/// because that is what production reads. The suite is serialized so the
/// shared schema-version key isn't trampled between parallel test cases.
@Suite("DataWriter.bootstrap", .serialized)
struct DataWriterBootstrapTests {
  private static let schemaVersionKey = "feeder_schema_version"

  /// Bumps the version key for assertions and clears it on teardown. Each
  /// test uses a unique seed value so concurrent runs don't trample each
  /// other when the suite runs in parallel.
  private static func makeIsolatedSchemaKey() -> Int {
    Int.random(in: 1_000_000...9_999_999)
  }

  @Test
  func firstLaunchSeedsDefaultsWhenVersionAlreadyStored() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaKey()
    // Simulate "store is empty but version key already matches" — e.g. the
    // store was opened, version persisted, then categories cleared manually.
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)

    let outcome = try await writer.bootstrap(currentSchemaVersion: version)

    #expect(outcome.action == .seeded)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    // +1 for the system uncategorized fallback.
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
    #expect(outcome.entryCount == 0)
    #expect(outcome.feedCount == 0)

    UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
  }

  @Test
  func steadyStateSkipsWhenCategoriesPresentAndVersionMatches() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaKey()
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)

    // First bootstrap seeds defaults.
    _ = try await writer.bootstrap(currentSchemaVersion: version)
    // Second bootstrap on the same store + same version should be a no-op.
    let outcome = try await writer.bootstrap(currentSchemaVersion: version)

    #expect(outcome.action == .skipped)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)

    UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
  }

  @Test
  func schemaVersionBumpResetsStoreAndReseeds() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let oldVersion = Self.makeIsolatedSchemaKey()
    let newVersion = oldVersion + 1
    UserDefaults.standard.set(oldVersion, forKey: Self.schemaVersionKey)
    UserDefaults.standard.set(Date(), forKey: lastSyncDateUserDefaultsKey)

    // Seed once with old version.
    _ = try await writer.bootstrap(currentSchemaVersion: oldVersion)

    // Bump version → should wipe + reseed.
    let outcome = try await writer.bootstrap(currentSchemaVersion: newVersion)

    if case .reset(let deletedEntries) = outcome.action {
      #expect(deletedEntries == 0)  // no entries yet on this in-memory store
    } else {
      Issue.record("Expected .reset action, got \(outcome.action)")
    }
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
    // lastSyncDate is cleared on reset so the next sync re-fetches fresh.
    #expect(UserDefaults.standard.object(forKey: lastSyncDateUserDefaultsKey) == nil)
    #expect(UserDefaults.standard.integer(forKey: Self.schemaVersionKey) == newVersion)

    UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
  }

  @Test
  func bootstrapInsertsUncategorizedAsSystemCategory() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaKey()
    UserDefaults.standard.set(version, forKey: Self.schemaVersionKey)

    _ = try await writer.bootstrap(currentSchemaVersion: version)

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })

    UserDefaults.standard.removeObject(forKey: Self.schemaVersionKey)
  }
}
