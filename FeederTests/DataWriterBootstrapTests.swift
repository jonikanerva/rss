import Foundation
import SwiftData
import Testing

@testable import Feeder

/// Bootstrap is the single entry point for startup-time reconciliation of
/// the persistent store. Each scenario (steady state, first-launch seed,
/// schema bump reset) is exercised against an **isolated, per-test**
/// `UserDefaults` suite. Production `bootstrap` defaults the suite name to
/// `nil` (→ `.standard`); the tests pass a per-test suite name so writes
/// here never leak into the developer's app preferences, and one test
/// cannot trample another's `feeder_schema_version` write. The previous
/// version of this suite wrote directly to `UserDefaults.standard`, and a
/// `defer { … removeObject … }` between tests could (under unlucky
/// ordering) leave the production app reading `0` on the next launch and
/// triggering a destructive bootstrap-reset wipe — see `fix(bootstrap)`
/// commit.
@Suite("DataWriter.bootstrap")
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

  /// Per-test `UserDefaults` suite. The suite name embeds a UUID so
  /// concurrent suites cannot collide; both the actor-side bootstrap call
  /// (re-opening the suite by name) and the test-side assertions
  /// (`defaults`) point at the same plist. The caller clears the persistent
  /// domain in `defer` to avoid leaving plist files behind in
  /// `~/Library/Preferences`.
  private static func makeIsolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "feeder.tests.bootstrap.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create isolated UserDefaults suite \(suiteName)")
    }
    return (defaults, suiteName)
  }

  // MARK: - Skipped / steady state

  @Test
  func steadyStateSkipsWhenCategoriesPresentAndVersionMatches() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defaults.set(version, forKey: Self.schemaVersionKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // First bootstrap seeds defaults.
    _ = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )
    // Second bootstrap on the same store + same version should be a no-op.
    let outcome = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )

    #expect(outcome.action == .skipped)
    #expect(outcome.folderCount == DefaultCategoryData.folders.count)
    #expect(outcome.categoryCount == DefaultCategoryData.categories.count + 1)
  }

  // MARK: - Seeded

  @Test
  func seedsDefaultsWhenStoreEmptyButVersionMatches() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    // "Store is empty but version key already matches" — e.g. the
    // store was opened, version persisted, then categories cleared manually.
    defaults.set(version, forKey: Self.schemaVersionKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let outcome = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )

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
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defaults.set(version, forKey: Self.schemaVersionKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    _ = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )

    let defs = try await writer.fetchCategoryDefinitions()
    #expect(defs.contains { $0.label == uncategorizedLabel })
  }

  // MARK: - Reset

  /// Real first-launch path: nothing in `UserDefaults`, store empty, so the
  /// integer read returns 0 and bootstrap must take the `.reset` branch.
  /// Guards against accidentally treating a missing key as "version matches".
  /// Empty store is critical — see `recoveryRestoresKeyWhenDataPresent` for
  /// the data-already-present recovery path that explicitly skips reset.
  @Test
  func firstLaunchWithEmptyVersionHitsResetPath() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let outcome = try await writer.bootstrap(
      currentSchemaVersion: Self.makeIsolatedSchemaVersion(),
      userDefaultsSuiteName: suiteName
    )

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
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defaults.set(oldVersion, forKey: Self.schemaVersionKey)
    defaults.set(Date(), forKey: lastSyncDateUserDefaultsKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Seed real data the reset must wipe.
    let subscription = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([subscription])
    let entries = [
      try FeedbinFixtures.entry(id: 5001, feedId: 100),
      try FeedbinFixtures.entry(id: 5002, feedId: 100),
      try FeedbinFixtures.entry(id: 5003, feedId: 100),
    ]
    let inserted = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))
    #expect(inserted == 3)

    try await writer.addFolder(label: "preexisting", displayName: "Preexisting", sortOrder: 0)
    try await writer.addCategory(
      label: "user_made", displayName: "User Made", description: "kept across reset?",
      sortOrder: 0, folderLabel: "preexisting"
    )

    // Bump version → wipe everything + reseed defaults.
    let outcome = try await writer.bootstrap(
      currentSchemaVersion: newVersion, userDefaultsSuiteName: suiteName
    )

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
    #expect(defaults.object(forKey: lastSyncDateUserDefaultsKey) == nil)
    #expect(defaults.integer(forKey: Self.schemaVersionKey) == newVersion)
  }

  // MARK: - Recovery (defense-in-depth)

  /// If the schema-version key is missing (read as 0) but the store already
  /// holds entries and categories, bootstrap must NOT wipe — it restores
  /// the key in place. Without this safety-net, a stray test that clears
  /// `UserDefaults.standard.feeder_schema_version` could destroy the
  /// developer's local data on the next app launch.
  @Test
  func recoveryRestoresKeyWhenDataPresentInsteadOfWiping() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defaults.set(version, forKey: Self.schemaVersionKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    // Populate the store (seed defaults + a feed + entries) at the correct
    // version, then simulate the bug: schema-version key disappears.
    _ = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )
    let subscription = try FeedbinFixtures.subscription(id: 1, feedId: 100)
    try await writer.syncFeeds([subscription])
    let entries = [try FeedbinFixtures.entry(id: 9001, feedId: 100)]
    _ = try await writer.persistEntries(entries, unreadIDs: Set(entries.map(\.id)))
    defaults.removeObject(forKey: Self.schemaVersionKey)

    // Bootstrap again. With data present + key missing the recovery branch
    // fires; the action surfaces as `.skipped` (no work needed) and the key
    // is restored.
    let outcome = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )

    #expect(outcome.action == .skipped)
    #expect(outcome.entryCount == 1)
    #expect(outcome.feedCount == 1)
    #expect(defaults.integer(forKey: Self.schemaVersionKey) == version)
  }

  /// Idempotency: a clean steady-state bootstrap must persist the current
  /// schema version even when the key already matched, so a transient
  /// missing key on the next launch still passes the recovery check.
  @Test
  func steadyStateAlwaysPersistsCurrentSchemaVersion() async throws {
    let writer = try await DataWriterTestSupport.makeWriter()
    let version = Self.makeIsolatedSchemaVersion()
    let (defaults, suiteName) = Self.makeIsolatedDefaults()
    defaults.set(version, forKey: Self.schemaVersionKey)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    _ = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )
    // Erase the key (mimicking the bug) and ensure subsequent bootstrap
    // restores it — there is no data yet, so this confirms the unconditional
    // `userDefaults.set(currentSchemaVersion, …)` write at end-of-method.
    defaults.removeObject(forKey: Self.schemaVersionKey)
    _ = try await writer.bootstrap(
      currentSchemaVersion: version, userDefaultsSuiteName: suiteName
    )

    #expect(defaults.integer(forKey: Self.schemaVersionKey) == version)
  }
}
