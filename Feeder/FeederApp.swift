import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch, articles
/// and feeds are deleted (categories preserved) and a fresh sync runs.
private let currentSchemaVersion = 15

@main
struct FeederApp: App {
  let modelContainer: ModelContainer

  @State
  private var syncEngine = SyncEngine()
  @State
  private var classificationEngine = ClassificationEngine()

  init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    let useInMemoryStore =
      processEnvironment["UITEST_IN_MEMORY_STORE"] == "1" || processEnvironment["UITEST_DEMO_MODE"] == "1"

    let schema = Schema([
      Feed.self,
      Entry.self,
      Category.self,
      Folder.self,
    ])
    let config = ModelConfiguration("Feeder", isStoredInMemoryOnly: useInMemoryStore)

    // If the store can't be opened (schema incompatible), delete it and retry
    do {
      modelContainer = try ModelContainer(for: schema, configurations: [config])
    } catch {
      logger.error("ModelContainer failed: \(error.localizedDescription). Deleting store and retrying.")
      Self.deleteStoreFiles()
      UserDefaults.standard.removeObject(forKey: "lastSyncDate")
      UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
      do {
        modelContainer = try ModelContainer(for: schema, configurations: [config])
      } catch {
        fatalError("Failed to create ModelContainer after reset: \(error)")
      }
    }

    if !useInMemoryStore {
      resetArticlesIfSchemaChanged()
    }

    let context = ModelContext(modelContainer)
    let feedCount = (try? context.fetchCount(FetchDescriptor<Feed>())) ?? 0
    let entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
    let categoryCount = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
    let folderCount = (try? context.fetchCount(FetchDescriptor<Folder>())) ?? 0

    if categoryCount == 0 {
      DefaultCategoryData.seed(into: context)
    }

    let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
    logger.info(
      "Startup: schema v\(currentSchemaVersion), \(feedCount) feeds, \(entryCount) entries, \(categoryCount) categories, \(folderCount) folders. Last sync: \(lastSync?.description ?? "never"). In-memory: \(useInMemoryStore)"
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(syncEngine)
        .environment(classificationEngine)
    }
    .modelContainer(modelContainer)
    .commands { FeederCommands() }

    Settings {
      SettingsView()
        .environment(syncEngine)
        .environment(classificationEngine)
        .modelContainer(modelContainer)
    }
    .windowResizability(.contentSize)
  }

  // First-launch seeding is a bootstrap exception: writes directly to
  // ModelContext during init(), before any views or @Query are active.
  // DataWriter is not yet available (SyncEngine.configure() hasn't been
  // called). This pattern matches resetArticlesIfSchemaChanged() below.
  //
  // See `Bootstrap/DefaultCategoryData.swift`.

  // MARK: - Schema versioning

  /// Clear all data when schema version changes (model shape may have changed).
  private func resetArticlesIfSchemaChanged() {
    let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
    guard stored != currentSchemaVersion else { return }

    logger.info("Schema version changed (\(stored) → \(currentSchemaVersion)). Clearing all data.")

    let context = ModelContext(modelContainer)
    let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
    for feed in feeds {
      context.delete(feed)
    }
    let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
    for entry in entries {
      context.delete(entry)
    }
    let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
    for category in categories {
      context.delete(category)
    }
    let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
    for folder in folders {
      context.delete(folder)
    }
    try? context.save()

    UserDefaults.standard.removeObject(forKey: "lastSyncDate")
    UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
    logger.info("All data cleared. Will re-seed and sync fresh.")
  }

  /// Delete SwiftData store files from disk (fallback when store can't be opened at all).
  private static func deleteStoreFiles() {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    for suffix in ["store", "store-shm", "store-wal"] {
      let url = appSupport.appendingPathComponent("Feeder.\(suffix)")
      try? FileManager.default.removeItem(at: url)
    }
  }
}

private let schemaVersionKey = "feeder_schema_version"
