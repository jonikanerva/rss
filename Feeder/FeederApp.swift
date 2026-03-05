import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

@main
struct FeederApp: App {
    let modelContainer: ModelContainer

    @State private var syncEngine = SyncEngine()
    @State private var classificationEngine = ClassificationEngine()
    @State private var groupingEngine = GroupingEngine()

    init() {
        do {
            let schema = Schema([
                Feed.self,
                Entry.self,
                Category.self,
                StoryGroup.self
            ])
            let config = ModelConfiguration("Feeder", isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [config])

            // Log persisted data counts on startup
            let context = ModelContext(modelContainer)
            let feedCount = (try? context.fetchCount(FetchDescriptor<Feed>())) ?? 0
            let entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
            let categoryCount = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0
            let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
            logger.info("Startup: \(feedCount) feeds, \(entryCount) entries, \(categoryCount) categories persisted. Last sync: \(lastSync?.description ?? "never")")
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(syncEngine)
                .environment(classificationEngine)
                .environment(groupingEngine)
        }
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
                .environment(syncEngine)
                .environment(classificationEngine)
                .environment(groupingEngine)
                .modelContainer(modelContainer)
        }
    }
}
