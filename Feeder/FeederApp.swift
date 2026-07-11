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
  /// Constructed via `makeClassificationEngine()` so that under `HeadlessMode`
  /// it carries the headless no-op provider — closing the OpenAI credential seam
  /// at construction (`buildProvider()` and its Keychain read are then never
  /// reached on an automated launch, even if a batch fired on seeded data).
  @State
  private var classificationEngine = FeederApp.makeClassificationEngine()
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
  /// Perf-only activation delegate. Constructed on every launch but INERT in
  /// shipping builds — both of its hooks early-return unless `FEEDER_PERF_MODE`
  /// is set (`PerfActivationAppDelegate`). It exists solely so the headless
  /// `make perf` launch (`xctrace record --launch`) foregrounds the app and
  /// orders its window front, which is what makes SwiftUI fire the
  /// `WindowGroup` window's `.onAppear`/`.task` — and therefore
  /// `ContentView → runPerfScenario()`. Without it the non-activated launch
  /// leaves the window undisplayed and the scenario never runs (issue #132).
  @NSApplicationDelegateAdaptor(PerfActivationAppDelegate.self)
  private var perfActivationDelegate

  init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    // Headless launches (any `FEEDER_HEADLESS=1` run — `make test` sets it on the
    // XCTest host) boot with an EMPTY in-memory store so they never load the real
    // reading DB. This is one half of the single-source headless gate:
    // `HeadlessMode.isEnabled` is the SAME property the credential-skip in
    // `ContentView.checkCredentials` reads, so the two can never diverge (no
    // on-disk store paired with a credential skip). The UITEST_* flags remain for
    // the existing UI-test modes.
    let useInMemoryStore =
      HeadlessMode.isEnabled
      || processEnvironment["UITEST_IN_MEMORY_STORE"] == "1"
      || processEnvironment["UITEST_DEMO_MODE"] == "1"

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

  /// Build the classification engine, injecting the headless no-op provider when
  /// `HeadlessMode.isEnabled`. The override is bound to an explicitly-typed local
  /// so the optional-closure type is unambiguous (a bare `cond ? { … } : nil` in
  /// the `@State` initialiser defeats inference). Reads the same single-source
  /// `HeadlessMode.isEnabled` as the store and credential gates (#141).
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
      // Attach the read-only companion: a separate actor owning a SECOND
      // read-only `ModelContext` on the SAME app container (`C_app`), created
      // now that `C_app` is up and bootstrapped. Its own actor/executor keeps
      // article-list + sidebar reads off the writer actor's mailbox (the
      // panel-2 starvation fix), while sharing one container/coordinator keeps
      // `PersistentIdentifier`s interoperable for the selection path. Because
      // it is just a 2nd context on `C_app` (born after `C_app`, dies with it),
      // there is no separate container to migrate or to hold a connection
      // across `init`'s destructive-reset fallback.
      let reader = await DataReader.makeDetached(modelContainer: modelContainer)
      syncEngine.attachReader(reader)
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

// MARK: - Perf activation delegate

/// `FEEDER_PERF_MODE`-gated `NSApplicationDelegate` that foregrounds the app
/// for the headless perf run and INERT otherwise.
///
/// Why it exists: `make perf` launches the app through `xctrace record
/// --launch`, which starts the process WITHOUT activating it. A non-activated
/// macOS app may never order its `WindowGroup` window on screen, so SwiftUI
/// never fires the window's `.onAppear`/`.task` — and `ContentView`'s
/// `checkCredentials() → runPerfScenario()` trigger (which only runs once the
/// window renders) never fires. The scenario then idles instead of driving the
/// nav walk and self-exiting, so no `perf-nav-window` signpost is emitted and
/// the parser has nothing to measure (issue #132).
///
/// Both hooks gate on `PerfScenarioRunner.isEnabled` as their FIRST statement —
/// the single `FEEDER_PERF_MODE` source of truth shared with
/// `ContentView.isPerfScenarioMode`, so the forced activation and the scenario
/// trigger can never diverge. In a shipping launch both return immediately:
/// the delegate is constructed-but-inert, adds no UI/menu/setting, and never
/// calls `exit()` (that stays in `PerfScenarioRunner`, at the end of the walk).
///
/// MainActor-isolated by default (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`);
/// every AppKit call here is MainActor-only, matching where AppKit delivers
/// these launch callbacks.
final class PerfActivationAppDelegate: NSObject, NSApplicationDelegate {
  /// Owned handle for the one-shot window-ordering retry (`STACK.md § 9`): the
  /// async work has an explicit owner rather than being fire-and-forget. It
  /// completes in a single main-actor hop, so no cancellation is needed beyond
  /// the app lifetime that bounds the delegate.
  private var windowOrderRetry: Task<Void, Never>?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Load-bearing gate — MUST stay the first statement. `FEEDER_PERF_MODE` is
    // the single source of truth for perf-only behaviour; a shipping launch
    // returns here and the delegate does nothing.
    guard PerfScenarioRunner.isEnabled else { return }
    // Force a normal foreground app so the window can become key and order
    // front. Set before launch finishes so the policy is in place by the time
    // SwiftUI creates the scene.
    NSApp.setActivationPolicy(.regular)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Same load-bearing gate — MUST stay the first statement (see above).
    guard PerfScenarioRunner.isEnabled else { return }
    // `activate()` is the current macOS 14+ API (NOT the deprecated
    // `activate(ignoringOtherApps:)`); it brings the app forward under the
    // cooperative activation model.
    NSApp.activate()
    if let window = NSApp.windows.first {
      // The load-bearing per-window primitive: activation alone does not
      // guarantee a specific window is key/ordered — this orders it front so
      // SwiftUI displays it and fires the window's `.onAppear`/`.task`.
      window.makeKeyAndOrderFront(nil)
    } else {
      // SwiftUI may not have created the `WindowGroup` window yet at
      // `didFinishLaunching`. ONE bounded, owned next-runloop-tick retry orders
      // it front once the window exists — a single self-correcting Task, never
      // a loop (`STACK.md § 7 / § 9`). If the window still is not there, no
      // render fires and the run fails closed downstream (the parser's
      // render-path floor refuses to report against an empty window).
      windowOrderRetry = Task { @MainActor in
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
      }
    }
  }
}
