import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch, articles
/// and feeds are deleted (categories preserved) and a fresh sync runs.
private let currentSchemaVersion = 6

@main
struct FeederApp: App {
    let modelContainer: ModelContainer

    @State private var syncEngine = SyncEngine()
    @State private var classificationEngine = ClassificationEngine()

    init() {
        let processEnvironment = ProcessInfo.processInfo.environment
        let useInMemoryStore =
            processEnvironment["UITEST_IN_MEMORY_STORE"] == "1" ||
            processEnvironment["UITEST_DEMO_MODE"] == "1"

        let schema = Schema([
            Feed.self,
            Entry.self,
            Category.self
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
        let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
        logger.info("Startup: schema v\(currentSchemaVersion), \(feedCount) feeds, \(entryCount) entries, \(categoryCount) categories. Last sync: \(lastSync?.description ?? "never"). In-memory: \(useInMemoryStore)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(syncEngine)
                .environment(classificationEngine)
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
                .environment(syncEngine)
                .environment(classificationEngine)
                .modelContainer(modelContainer)
        }
        .windowResizability(.contentSize)
    }

    // MARK: - Schema versioning

    /// Clear articles and feeds when schema version changes. Categories are preserved.
    private func resetArticlesIfSchemaChanged() {
        let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
        guard stored != currentSchemaVersion else { return }

        logger.info("Schema version changed (\(stored) → \(currentSchemaVersion)). Clearing articles.")

        let context = ModelContext(modelContainer)
        let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
        for feed in feeds {
            context.delete(feed) // cascade deletes feed's entries
        }
        // Delete any orphaned entries (no feed)
        let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
        for entry in entries {
            context.delete(entry)
        }
        try? context.save()

        UserDefaults.standard.removeObject(forKey: "lastSyncDate")
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        logger.info("Articles cleared. Categories preserved. Will sync fresh.")
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
