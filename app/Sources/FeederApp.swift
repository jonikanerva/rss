import SwiftUI
import SwiftData

@main
struct FeederApp: App {
    let modelContainer: ModelContainer

    @State private var syncEngine = SyncEngine()
    @State private var classificationEngine = ClassificationEngine()

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
}
