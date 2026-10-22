import AppKit
import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

@main
struct FeederApp: App {
  let storeConfiguration: ModelConfiguration
  /// `StoreRecovery` sets this phase. A failed open keeps every store file.
  @State
  private var storePhase: StorePhase

  @State
  private var syncEngine = FeederApp.makeSyncEngine(environment: ProcessInfo.processInfo.environment)
  /// Built by `makeClassificationEngine()`, so a headless launch carries the
  /// no-op provider and never reaches `buildProvider()` or its Keychain read.
  @State
  private var classificationEngine = FeederApp.makeClassificationEngine()
  @State
  private var bootstrapPhase: BootstrapPhase = .pending
  /// A reopen during `.pending`, from the Dock or from Window → Feeder, creates
  /// a new window and a new bootstrap task. This flag keeps one bootstrap run
  /// per store open.
  @State
  private var isBootstrapRunning = false
  /// App-wide font settings, injected into both scenes. A size change
  /// re-renders only the views that read a font alias, so `ContentView`'s
  /// selection, focus, and scroll anchor survive it.
  @State
  private var fontSettings = AppFontSettings()
  /// Declare no second adaptor: SwiftUI allows one per app, so every app
  /// delegate hook belongs in `FeederAppDelegate`.
  @NSApplicationDelegateAdaptor(FeederAppDelegate.self)
  private var appDelegate

  init() {
    let useInMemoryStore = Self.usesInMemoryStores(in: ProcessInfo.processInfo.environment)
    let configuration = Self.makeStoreConfiguration(isStoredInMemoryOnly: useInMemoryStore)
    storeConfiguration = configuration

    // The `ModelContainer` open runs synchronously on MainActor, here and in
    // Start Over. `DataWriter.bootstrap()` handles everything after it on the
    // background actor.
    do {
      _storePhase = State(
        initialValue: try StoreRecovery.openStore(
          isStoredInMemoryOnly: useInMemoryStore,
          open: { try Self.openContainer(configuration) }
        ))
    } catch {
      logger.error("In-memory ModelContainer open failed: \(error.localizedDescription, privacy: .private)")
      fatalError("In-memory ModelContainer open failed: \(error)")
    }
  }

  /// `FeederMigrationPlan` carries an older store forward with lightweight
  /// stages, so it migrates up on the first launch.
  private static func makeStoreConfiguration(isStoredInMemoryOnly: Bool) -> ModelConfiguration {
    let schema = Schema(versionedSchema: FeederSchemaV3.self)
    return ModelConfiguration("Feeder", schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly)
  }

  private static func openContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
    let schema = Schema(versionedSchema: FeederSchemaV3.self)
    return try ModelContainer(for: schema, migrationPlan: FeederMigrationPlan.self, configurations: configuration)
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

  // MARK: - Launch gates

  /// The only gate for both the in-memory data store and the memory credential
  /// store. Never choose either store elsewhere: a launch with an empty data
  /// store must never read the owner's Keychain item.
  nonisolated static func usesInMemoryStores(in environment: [String: String]) -> Bool {
    HeadlessMode.isEnabled(in: environment)
  }

  /// False for exactly the launches that `ContentView.bootLaunchMode()` boots.
  nonisolated static func usesFeedbinAccount(in environment: [String: String]) -> Bool {
    !HeadlessMode.isEnabled(in: environment)
      && environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
  }

  static func makeSyncEngine(environment: [String: String]) -> SyncEngine {
    let store: any FeedbinCredentialStore =
      usesInMemoryStores(in: environment) ? MemoryFeedbinCredentialStore() : KeychainFeedbinCredentialStore()
    guard usesFeedbinAccount(in: environment) else {
      return SyncEngine(credentialStore: store, account: .unused) { _ in InertFeedbinClient() }
    }
    return SyncEngine(credentialStore: store)
  }

  var body: some Scene {
    WindowGroup(id: MainWindow.sceneID, for: MainWindow.self) { _ in
      newMainWindowContent
    } defaultValue: {
      .main
    }
    .commands { FeederCommands() }

    Settings {
      settingsContent
        .environment(syncEngine)
        .environment(classificationEngine)
        .environment(fontSettings)
        .defaultAppStorage(AppDefaults.current)
    }
    .windowResizability(.contentSize)
  }

  // MARK: - Store gate

  /// The content of each new main window. The removal must run before the
  /// window's split view exists (`SplitViewAutosaveReset`). SwiftUI also
  /// reads this when the scene state changes; a repeated removal is harmless.
  private var newMainWindowContent: some View {
    SplitViewAutosaveReset.removeStaleFrames()
    return
      mainWindowContent
      .environment(syncEngine)
      .environment(classificationEngine)
      .environment(fontSettings)
      .defaultAppStorage(AppDefaults.current)
  }

  @ViewBuilder
  private var mainWindowContent: some View {
    switch storePhase {
    case .ready(let container):
      bootstrapGate(container: container)
        .modelContainer(container)
    case .failed(let failure):
      StoreRecoveryView(failure: failure, startOver: startOver)
    }
  }

  @ViewBuilder
  private var settingsContent: some View {
    switch storePhase {
    case .ready(let container):
      SettingsView()
        .modelContainer(container)
    case .failed:
      StoreUnavailableSettingsView()
    }
  }

  private func startOver() {
    let configuration = storeConfiguration
    bootstrapPhase = .pending
    storePhase = StoreRecovery.startOver(
      storeURL: configuration.url,
      backupFolderName: StoreRecovery.backupFolderName(at: .now, id: UUID()),
      defaults: AppDefaults.current,
      fileSystem: .live,
      open: { try Self.openContainer(configuration) }
    )
  }

  // MARK: - Bootstrap gate

  enum BootstrapPhase {
    case pending
    case ready(StoreActors)
    case failed(String)
  }

  @ViewBuilder
  private func bootstrapGate(container: ModelContainer) -> some View {
    switch bootstrapPhase {
    case .pending:
      bootstrapPendingView
        .task { await runBootstrap(container: container) }
    case .ready(let store):
      ContentView(store: store, readQueue: syncEngine)
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
        NSWorkspace.shared.activateFileViewerSelecting([storeConfiguration.url.deletingLastPathComponent()])
      }
      Button("Quit Feeder") { NSApp.terminate(nil) }
    }
  }

  /// Run the single bootstrap entry point on the `DataWriter` background
  /// actor, then inject the writer into `SyncEngine`. Schema migration runs
  /// inside the `ModelContainer` open in `init`; bootstrap only seeds taxonomy
  /// on a freshly created store.
  private func runBootstrap(container: ModelContainer) async {
    guard !isBootstrapRunning else { return }
    isBootstrapRunning = true
    defer { isBootstrapRunning = false }
    appDelegate.syncEngine = syncEngine
    appDelegate.classificationEngine = classificationEngine
    let writer = await DataWriter.makeDetached(modelContainer: container)
    do {
      let outcome = try await writer.bootstrap()
      let lastSync = AppDefaults.current.object(forKey: lastSyncDateUserDefaultsKey) as? Date
      logger.info(
        "Startup: action=\(String(describing: outcome.action)), feeds=\(outcome.feedCount), entries=\(outcome.entryCount), categories=\(outcome.categoryCount), folders=\(outcome.folderCount). Last sync: \(lastSync?.description ?? "never")."
      )
      syncEngine.attachWriter(writer)
      let classificationEngine = classificationEngine
      syncEngine.attachAccountSwitchWork(
        pause: { await classificationEngine.pauseForAccountSwitch() },
        resume: { classificationEngine.resumeAfterAccountSwitch(writer: $0) })
      // Keep this after `attachWriter` and before `.ready`, so that the first
      // list render and the first sidebar counts show the queued reads as read.
      await syncEngine.applyQueuedReads()
      // The read-only companion is created only once the container is up and
      // bootstrapped. It is a second context on that same container, so there
      // is no separate store to migrate.
      let reader = await DataReader.makeDetached(modelContainer: container)
      bootstrapPhase = .ready(StoreActors(writer: writer, reader: reader))
    } catch {
      logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .private)")
      bootstrapPhase = .failed(error.localizedDescription)
    }
  }
}

// MARK: - App delegate

/// The app's `NSApplicationDelegate`. At activation it lets the classification
/// engine end a loop wait. At quit it queues each pending read that this launch
/// has not queued yet. It adds no UI and never calls `exit()`.
final class FeederAppDelegate: NSObject, NSApplicationDelegate {
  /// `FeederApp` owns the engines and sets these references in its bootstrap.
  weak var syncEngine: SyncEngine?
  weak var classificationEngine: ClassificationEngine?

  // MARK: - Launch

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Feeder has one main window. A window tab is a second window, so remove
    // the tab commands and the tab bar's new-tab button.
    NSWindow.allowsAutomaticWindowTabbing = false
  }

  // MARK: - Activation

  func applicationDidBecomeActive(_ notification: Notification) {
    classificationEngine?.applicationDidBecomeActive()
  }

  // MARK: - Quit

  func applicationWillTerminate(_ notification: Notification) {
    // Keep this call synchronous: the process exits when this method returns,
    // so a Task or an actor hop started here can be lost (`STACK.md § 14`).
    syncEngine?.queueRecordedPendingReads()
  }
}
