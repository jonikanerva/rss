import Foundation
import SwiftData
import Synchronization

@testable import Feeder

/// Shared test helpers for DataWriter integration tests.
enum DataWriterTestSupport {
  /// Build a writer wired to an in-memory container and an isolated
  /// in-memory flag store. The isolated store is what keeps the seeded-
  /// defaults sentinel deterministic across the test target — a flag set
  /// by an earlier test cannot bleed into a later one because each writer
  /// gets its own store instance.
  static func makeWriter() async throws -> DataWriter {
    let container = try makeInMemoryContainer()
    return DataWriter(modelContainer: container, defaultsFlagStore: InMemoryFlagStore())
  }

  /// On-disk temp container (WAL — the production journal mode) at a unique
  /// store URL. Used ONLY by the isolated 1+1 stress test (which needs
  /// production's WAL journal mode); the light reader-using suites use the fast
  /// in-memory container. Concurrent coordinators are capped by the `make test`
  /// gate's `-parallel-testing-enabled NO` (serial run), not by the per-suite
  /// `@Suite(.serialized)` traits (STACK.md §14).
  static func makeOnDiskContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("FeederReaderTest-\(UUID().uuidString).store")
    let config = ModelConfiguration(schema: schema, url: url)
    return try ModelContainer(
      for: schema, migrationPlan: FeederMigrationPlan.self, configurations: config)
  }

  /// Build a read-only `DataReader` as a SECOND `ModelContext` on the SAME
  /// container the writer owns (option (i) — shared `C_app`). One container ⇒
  /// one coordinator ⇒ `PersistentIdentifier`s minted by the reader resolve in
  /// the writer / MainActor context (render + selection path unchanged).
  static func makeReader(sharing writer: DataWriter) async -> DataReader {
    await DataReader.makeDetached(modelContainer: writer.modelContainer)
  }

  /// Writer + read-only reader over ONE shared in-memory container — the
  /// canonical setup for the read/write split (option (i)). In-memory keeps the
  /// light reader suites fast. Concurrent coordinators are capped by the `make
  /// test` gate's `-parallel-testing-enabled NO` (serial run), not by the
  /// per-suite `@Suite(.serialized)` traits, which only order tests within a
  /// suite (STACK.md §14).
  static func makeWriterAndReader() async throws -> (DataWriter, DataReader) {
    let writer = try await makeWriter()
    let reader = await DataReader.makeDetached(modelContainer: writer.modelContainer)
    return (writer, reader)
  }

  /// Creates an in-memory `ModelContainer` with the full app schema for tests
  /// that need direct `ModelContext` access (e.g. pure-function tests that
  /// insert SwiftData models without going through `DataWriter`).
  /// Routes through `FeederSchemaV2` + `FeederMigrationPlan` so tests
  /// exercise the same container shape production uses — if a future
  /// schema bump breaks the migration plan, these tests fail loudly
  /// instead of opening a bare schema that diverges from production.
  static func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(
      for: schema,
      migrationPlan: FeederMigrationPlan.self,
      configurations: config
    )
  }
}

/// Per-test in-memory implementation of `SeededDefaultsFlagStore`.
/// `Mutex` keeps the underlying dictionary `Sendable`-safe so the store
/// can cross the `Task.detached` boundary `DataWriter.makeDetached` uses.
/// Bootstrap exercises a single key (`defaultsSeededUserDefaultsKey`), so
/// the storage is intentionally minimal.
final class InMemoryFlagStore: SeededDefaultsFlagStore {
  private let storage = Mutex<[String: Bool]>([:])

  func isSeeded(forKey key: String) -> Bool {
    storage.withLock { $0[key] ?? false }
  }

  func setSeeded(_ value: Bool, forKey key: String) {
    storage.withLock { $0[key] = value }
  }
}

/// Lightweight snapshot of an Entry for test assertions without crossing actor boundaries.
struct EntrySnapshot: Sendable {
  let feedbinEntryID: Int
  let isRead: Bool
  let isClassified: Bool
  let primaryCategory: String
  let primaryFolder: String
  let plainText: String
  let persistentModelID: PersistentIdentifier
}

// MARK: - Test-only concurrency gate

/// Minimal `Sendable` boolean flag for test gates. `Atomic` is `~Copyable`, so
/// it cannot cross a `Task` / actor boundary by value; wrapping it in a `final
/// class` with only an immutable stored `Atomic` gives a shareable `Sendable`
/// reference the test and the gated writer op both hold.
final class AtomicFlag: Sendable {
  private let storage = Atomic<Bool>(false)
  var isSet: Bool { storage.load(ordering: .acquiring) }
  func set() { storage.store(true, ordering: .releasing) }
}

// MARK: - DataReader read-only invariant probe (test-only)

extension DataReader {
  /// Test-only: exposes whether the reader's context has unsaved changes. The
  /// reader must NEVER write, so this is expected to stay `false` after any
  /// fetch — a stray insert/save would leak uncommitted state into results.
  var testHasPendingChanges: Bool { modelContext.hasChanges }
}

// MARK: - Gated writer hooks (test-only concurrency probes)

extension DataWriter {
  /// Test-only: resolve a `PersistentIdentifier` minted by the `DataReader`
  /// (a 2nd context on the SAME container) to an `Entry` in THIS writer's
  /// context via `model(for:)`, returning its `feedbinEntryID`, or `nil` if it
  /// does not resolve to a live row. Proves the reader's IDs are interoperable
  /// with the writer / MainActor context — the production `ContentView`
  /// selection path resolves reader-returned IDs exactly this way.
  func testResolveEntry(_ id: PersistentIdentifier) -> Int? {
    guard let entry = modelContext.model(for: id) as? Entry else { return nil }
    return entry.feedbinEntryID
  }

  /// Apply a reclassification (category / folder / `isClassified`) to an entry
  /// but SUSPEND before `save()` until the test yields on `gate`. Lets a test
  /// assert a `DataReader` on a second context does NOT observe the uncommitted
  /// mutation (never a torn "classified with empty category" row), then — after
  /// release — sees it fully committed. `started` signals the mutation is
  /// applied-but-unsaved. TEST-ONLY.
  func gatedReclassify(
    feedbinEntryID id: Int, category: String, folder: String,
    started: AtomicFlag, gate: AsyncStream<Void>
  ) async throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.feedbinEntryID == id }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return }
    entry.primaryCategory = category
    entry.primaryFolder = folder
    entry.isClassified = true
    started.set()
    // Suspend until the test yields on the gate — the mutation is NOT yet
    // saved, so a second context must not observe it.
    for await _ in gate { break }
    try modelContext.save()
  }

  /// Test-only: wipe every persisted row so a fresh fixture can be re-seeded on
  /// the SAME container. The C3 measurement reuses ONE on-disk container across
  /// all reps (churning many coordinators flakily crashes the test host — the
  /// proven-safe shape is one reused container, `DataReaderConcurrencyTests`),
  /// resetting between reps to keep each rep isolated.
  func resetStoreForMeasurement() throws {
    // Individual deletes (not `delete(model:)`) so the object graph is managed —
    // a batch delete trips Entry's mandatory `feed` inverse constraint. Entries
    // first (children), then the taxonomy/feeds.
    for entry in try modelContext.fetch(FetchDescriptor<Entry>()) { modelContext.delete(entry) }
    for feed in try modelContext.fetch(FetchDescriptor<Feed>()) { modelContext.delete(feed) }
    for category in try modelContext.fetch(FetchDescriptor<Feeder.Category>()) {
      modelContext.delete(category)
    }
    for folder in try modelContext.fetch(FetchDescriptor<Folder>()) { modelContext.delete(folder) }
    try modelContext.save()
  }

  func fetchEntrySnapshot(feedbinEntryID id: Int) throws -> EntrySnapshot? {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.feedbinEntryID == id }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return nil }
    return EntrySnapshot(
      feedbinEntryID: entry.feedbinEntryID,
      isRead: entry.isRead,
      isClassified: entry.isClassified,
      primaryCategory: entry.primaryCategory,
      primaryFolder: entry.primaryFolder,
      plainText: entry.plainText,
      persistentModelID: entry.persistentModelID
    )
  }
}
