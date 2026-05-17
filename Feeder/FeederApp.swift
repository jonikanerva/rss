import AppKit
import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch, articles
/// and feeds are deleted (categories preserved) and a fresh sync runs.
private let currentSchemaVersion = 16

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

    let schema = Schema([
      Feed.self,
      Entry.self,
      Category.self,
      Folder.self,
    ])
    let config = ModelConfiguration("Feeder", isStoredInMemoryOnly: useInMemoryStore)

    // If the store can't be opened (schema incompatible), delete it and retry.
    // This is the only place we still do a synchronous `ModelContainer` open
    // on MainActor — `DataWriter.bootstrap()` handles everything past this
    // line on the background actor.
    do {
      modelContainer = try ModelContainer(for: schema, configurations: [config])
    } catch {
      logger.error("ModelContainer failed: \(error.localizedDescription). Deleting store and retrying.")
      Self.deleteStoreFiles()
      UserDefaults.standard.removeObject(forKey: lastSyncDateUserDefaultsKey)
      do {
        modelContainer = try ModelContainer(for: schema, configurations: [config])
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
  /// rest of the app can use it.
  private func runBootstrap() async {
    let writer = await DataWriter.makeDetached(modelContainer: modelContainer)
    do {
      let outcome = try await writer.bootstrap(currentSchemaVersion: currentSchemaVersion)
      let lastSync = UserDefaults.standard.object(forKey: lastSyncDateUserDefaultsKey) as? Date
      logger.info(
        "Startup: schema v\(currentSchemaVersion), action=\(String(describing: outcome.action)), feeds=\(outcome.feedCount), entries=\(outcome.entryCount), categories=\(outcome.categoryCount), folders=\(outcome.folderCount). Last sync: \(lastSync?.description ?? "never")."
      )
      syncEngine.attachWriter(writer)
      bootstrapPhase = .ready
    } catch {
      logger.error("Bootstrap failed: \(error.localizedDescription)")
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
