import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch the local
/// database is deleted and a fresh sync starts from scratch.
private let currentSchemaVersion = 2

@main
struct FeederApp: App {
    let modelContainer: ModelContainer

    @State private var syncEngine = SyncEngine()
    @State private var classificationEngine = ClassificationEngine()

    init() {
        do {
            let processEnvironment = ProcessInfo.processInfo.environment
            let useInMemoryStore =
                processEnvironment["UITEST_IN_MEMORY_STORE"] == "1" ||
                processEnvironment["UITEST_DEMO_MODE"] == "1"

            if !useInMemoryStore {
                Self.resetStoreIfSchemaChanged()
            }

            let schema = Schema([
                Feed.self,
                Entry.self,
                Category.self
            ])
            let config = ModelConfiguration("Feeder", isStoredInMemoryOnly: useInMemoryStore)
            modelContainer = try ModelContainer(for: schema, configurations: [config])

            // Log persisted data counts on startup
            let context = ModelContext(modelContainer)
            let feedCount = (try? context.fetchCount(FetchDescriptor<Feed>())) ?? 0
            let entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
            let categoryCount = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
            let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
            logger.info("Startup: schema v\(currentSchemaVersion), \(feedCount) feeds, \(entryCount) entries, \(categoryCount) categories. Last sync: \(lastSync?.description ?? "never"). In-memory: \(useInMemoryStore)")
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
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
    }

    // MARK: - Schema versioning

    private static let schemaVersionKey = "feeder_schema_version"

    private static func resetStoreIfSchemaChanged() {
        let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
        guard stored != currentSchemaVersion else { return }

        logger.info("Schema version changed (\(stored) → \(currentSchemaVersion)). Deleting local database.")

        // Delete SwiftData store files
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeName = "Feeder"
        for suffix in ["store", "store-shm", "store-wal"] {
            let url = appSupport.appendingPathComponent("\(storeName).\(suffix)")
            try? FileManager.default.removeItem(at: url)
        }

        // Clear lastSyncDate so a full sync runs
        UserDefaults.standard.removeObject(forKey: "lastSyncDate")

        // Save new version
        UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
        logger.info("Database reset complete. Will sync fresh on next launch.")
    }
}
