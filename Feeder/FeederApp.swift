import AppKit
import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

@main
struct FeederApp: App {
  let modelContainer: ModelContainer

  @State
  private var syncEngine = SyncEngine()
  @State
  private var classificationEngine = ClassificationEngine()
  @State
  private var bootstrapPhase: BootstrapPhase = .pending
  /// App-wide font settings. `AppFontSettings` is `@Observable`, owns the
  /// persisted `textSize`, and exposes every font alias the app renders.
  /// Injected into both scenes via `.environment(fontSettings)` so any view
  /// with `@Environment(AppFontSettings.self)` re-renders precisely the rows
  /// that read a font when the user picks a new size — `ContentView`'s
  /// `@State` (selection, focus, scroll anchor) stays intact.
  @State
  private var fontSettings = AppFontSettings()

  init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    let useInMemoryStore =
      processEnvironment["UITEST_IN_MEMORY_STORE"] == "1" || processEnvironment["UITEST_DEMO_MODE"] == "1"

    // `Schema(versionedSchema:)` resolves the `@Model` types and version
    // identifier `FeederSchemaV2` advertises; the resulting `Schema` is
    // what `ModelContainer` accepts alongside the migration plan. The
    // plan in `FeederMigrationPlan` carries V1 forward via a lightweight
    // stage, so stores still on V1 migrate up on first launch.
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let config = ModelConfiguration("Feeder", schema: schema, isStoredInMemoryOnly: useInMemoryStore)

    // SwiftData opens the store against `FeederSchemaV2` and applies the
    // stages declared in `FeederMigrationPlan` — a V1-on-disk store is
    // migrated lightweight-style to V2 here. The
    // fallback below survives non-schema corruption only (unreadable
    // store file, locked WAL, etc.). This is the only place we still do
    // a synchronous `ModelContainer` open on MainActor — `DataWriter.bootstrap()`
    // handles everything past this line on the background actor.
    do {
      modelContainer = try ModelContainer(
        for: schema,
        migrationPlan: FeederMigrationPlan.self,
        configurations: config
      )
    } catch {
      logger.error(
        "ModelContainer failed: \(error.localizedDescription, privacy: .private). Deleting store and retrying."
      )
      Self.deleteStoreFiles()
      UserDefaults.standard.removeObject(forKey: lastSyncDateUserDefaultsKey)
      do {
        modelContainer = try ModelContainer(
          for: schema,
          migrationPlan: FeederMigrationPlan.self,
          configurations: config
        )
      } catch {
        fatalError("Failed to create ModelContainer after reset: \(error)")
      }
    }
  }

  var body: some Scene {
    WindowGroup {
      bootstrapGate
        .environment(syncEngine)
        .environment(classificationEngine)
        .environment(fontSettings)
    }
    .modelContainer(modelContainer)
    .commands { FeederCommands() }

    Settings {
      SettingsView()
        .environment(syncEngine)
        .environment(classificationEngine)
        .environment(fontSettings)
        .modelContainer(modelContainer)
    }
    .windowResizability(.contentSize)
  }

  // MARK: - Bootstrap gate

  enum BootstrapPhase {
    case pending
    case ready
    case failed(String)
  }

  @ViewBuilder
  private var bootstrapGate: some View {
    switch bootstrapPhase {
    case .pending:
      bootstrapPendingView
        .task { await runBootstrap() }
    case .ready:
      ContentView()
    case .failed(let message):
      bootstrapFailedView(message: message)
    }
  }

  private var bootstrapPendingView: some View {
    // HIG (macOS): avoid labeling a spinning progress indicator. A plain
    // large spinner centred in the window matches the "calm/native" pattern
    // — no launch-card decoration to compete with system chrome.
    ProgressView()
      .controlSize(.large)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func bootstrapFailedView(message: String) -> some View {
    ContentUnavailableView {
      Label("Couldn't open your feeds", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Show in Finder") {
        if let url = Self.storeDirectoryURL() {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
      Button("Quit Feeder") { NSApp.terminate(nil) }
    }
  }

  /// Run the single bootstrap entry point on the `DataWriter` background
  /// actor. Constructs the writer via the shared `makeDetached` helper,
  /// runs `bootstrap()`, then injects the writer into `SyncEngine` so the
  /// rest of the app can use it. Schema migration itself runs inside the
  /// `ModelContainer` open in `init` — bootstrap only seeds taxonomy on
  /// a freshly-created store, so the data layer can survive a schema
  /// bump without losing folders, categories, or classified entries.
  private func runBootstrap() async {
    let writer = await DataWriter.makeDetached(modelContainer: modelContainer)
    do {
      let outcome = try await writer.bootstrap()
      let lastSync = UserDefaults.standard.object(forKey: lastSyncDateUserDefaultsKey) as? Date
      logger.info(
        "Startup: action=\(String(describing: outcome.action)), feeds=\(outcome.feedCount), entries=\(outcome.entryCount), categories=\(outcome.categoryCount), folders=\(outcome.folderCount). Last sync: \(lastSync?.description ?? "never")."
      )
      syncEngine.attachWriter(writer)
      bootstrapPhase = .ready
    } catch {
      logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .private)")
      bootstrapPhase = .failed(error.localizedDescription)
    }
  }

  // MARK: - Disk fallback

  /// Delete SwiftData store files from disk (fallback when store can't be opened at all).
  private static func deleteStoreFiles() {
    guard let appSupport = storeDirectoryURL() else { return }
    for suffix in ["store", "store-shm", "store-wal"] {
      let url = appSupport.appendingPathComponent("Feeder.\(suffix)")
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Directory that hosts the SwiftData store files — Application Support.
  /// Used by both `deleteStoreFiles()` and the "Show in Finder" recovery
  /// action so a user can inspect the location if bootstrap fails.
  private static func storeDirectoryURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }
}
