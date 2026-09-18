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
  /// Built by `makeClassificationEngine()`, so a headless launch carries the
  /// no-op provider and never reaches `buildProvider()` or its Keychain read.
  @State
  private var classificationEngine = FeederApp.makeClassificationEngine()
  @State
  private var bootstrapPhase: BootstrapPhase = .pending
  /// App-wide font settings, injected into both scenes. A size change
  /// re-renders only the views that read a font alias, so `ContentView`'s
  /// selection, focus, and scroll anchor survive it.
  @State
  private var fontSettings = AppFontSettings()
  /// Perf-only activation delegate. Constructed on every launch but inert in a
  /// shipping build: both hooks return early unless `FEEDER_PERF_MODE` is set.
  @NSApplicationDelegateAdaptor(PerfActivationAppDelegate.self)
  private var perfActivationDelegate

  init() {
    // Must run before any window or split view exists, so the split view lays
    // out both leading columns at the `ideal` widths Feeder stores itself.
    // `STACK.md § 14` records the reliance on the undocumented key name.
    SplitViewAutosaveReset.removeStaleFrames()

    let processEnvironment = ProcessInfo.processInfo.environment
    // A headless launch boots with an empty in-memory store, so it never opens
    // the real reading database. This gate and the credential skip in
    // `ContentView.checkCredentials` read the same `HeadlessMode.isEnabled`, so
    // an on-disk store can never pair with a credential skip.
    let useInMemoryStore =
      HeadlessMode.isEnabled
      || processEnvironment["UITEST_IN_MEMORY_STORE"] == "1"
      || processEnvironment["UITEST_DEMO_MODE"] == "1"

    // `FeederMigrationPlan` carries a V1 store forward with a lightweight
    // stage, so it migrates up on the first launch.
    let schema = Schema(versionedSchema: FeederSchemaV2.self)
    let config = ModelConfiguration("Feeder", schema: schema, isStoredInMemoryOnly: useInMemoryStore)

    // The fallback below covers non-schema corruption only, such as an
    // unreadable store file or a locked WAL. This is the one synchronous
    // `ModelContainer` open on MainActor; `DataWriter.bootstrap()` handles
    // everything past this line on the background actor.
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

  /// Build the classification engine, injecting the headless no-op provider
  /// when `HeadlessMode.isEnabled`. The override needs an explicitly typed
  /// local: a bare conditional in the `@State` initialiser defeats inference.
  private static func makeClassificationEngine() -> ClassificationEngine {
    let headlessOverride: (@Sendable () -> any ClassificationProvider)? =
      HeadlessMode.isEnabled
      ? { @Sendable () -> any ClassificationProvider in HeadlessClassificationProvider() }
      : nil
    return ClassificationEngine(providerFactoryOverride: headlessOverride)
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
    // The macOS HIG says not to label a spinning progress indicator, so this
    // stays a plain centred spinner.
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
  /// actor, then inject the writer into `SyncEngine`. Schema migration runs
  /// inside the `ModelContainer` open in `init`; bootstrap only seeds taxonomy
  /// on a freshly created store.
  private func runBootstrap() async {
    let writer = await DataWriter.makeDetached(modelContainer: modelContainer)
    do {
      let outcome = try await writer.bootstrap()
      let lastSync = UserDefaults.standard.object(forKey: lastSyncDateUserDefaultsKey) as? Date
      logger.info(
        "Startup: action=\(String(describing: outcome.action)), feeds=\(outcome.feedCount), entries=\(outcome.entryCount), categories=\(outcome.categoryCount), folders=\(outcome.folderCount). Last sync: \(lastSync?.description ?? "never")."
      )
      syncEngine.attachWriter(writer)
      // The read-only companion is created only once the container is up and
      // bootstrapped. It is a second context on that same container, so there
      // is no separate store to migrate and no connection held across the
      // destructive-reset fallback in `init`.
      let reader = await DataReader.makeDetached(modelContainer: modelContainer)
      syncEngine.attachReader(reader)
      bootstrapPhase = .ready
    } catch {
      logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .private)")
      bootstrapPhase = .failed(error.localizedDescription)
    }
  }

  // MARK: - Disk fallback

  /// Delete the SwiftData store files. The fallback for a store that cannot be
  /// opened at all.
  private static func deleteStoreFiles() {
    guard let appSupport = storeDirectoryURL() else { return }
    for suffix in ["store", "store-shm", "store-wal"] {
      let url = appSupport.appendingPathComponent("Feeder.\(suffix)")
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Directory that holds the SwiftData store files. Shared by
  /// `deleteStoreFiles()` and the "Show in Finder" recovery action.
  private static func storeDirectoryURL() -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
  }
}

// MARK: - Perf activation delegate

/// The app's single `NSApplicationDelegate`. Its hooks foreground the app for
/// the headless perf run and are otherwise inert.
///
/// `xctrace record --launch` starts the process without activating it, and a
/// non-activated macOS app may never order its `WindowGroup` window on screen.
/// SwiftUI then never fires the window's `.onAppear` or `.task`, so the perf
/// scenario never starts.
///
/// Both hooks gate on `PerfScenarioRunner.isEnabled` as their first statement,
/// the same source of truth `ContentView` reads, so the forced activation and
/// the scenario trigger cannot diverge. In a shipping launch both return at
/// once: the delegate adds no UI and never calls `exit()`.
final class PerfActivationAppDelegate: NSObject, NSApplicationDelegate {
  /// Owned handle for the one-shot window-ordering retry, so the async work is
  /// not fire-and-forget (`STACK.md § 9`). It completes in one main-actor hop,
  /// and the delegate's lifetime bounds it.
  private var windowOrderRetry: Task<Void, Never>?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Load-bearing gate: keep it the first statement. A shipping launch
    // returns here and the delegate does nothing.
    guard PerfScenarioRunner.isEnabled else { return }
    // Force a normal foreground app so the window can become key. Set before
    // launch finishes, so the policy holds when SwiftUI creates the scene.
    NSApp.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Load-bearing gate: keep it the first statement.
    guard PerfScenarioRunner.isEnabled else { return }
    // `activate()` brings the app forward under the cooperative activation
    // model.
    NSApp.activate()
    if let window = NSApp.windows.first {
      // Activation alone does not order a specific window front, and SwiftUI
      // fires `.onAppear` and `.task` only for a displayed window.
      window.makeKeyAndOrderFront(nil)
    } else {
      // SwiftUI may not have created the window yet at `didFinishLaunching`.
      // One owned next-tick retry orders it front once the window exists —
      // never a loop (`STACK.md § 7 / § 9`). With no window the run fails
      // closed downstream.
      windowOrderRetry = Task { @MainActor in
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
    }
  }
}
