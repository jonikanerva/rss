import Foundation
import SwiftData
import SwiftUI
import os.signpost

// MARK: - Content View root (issue #146 final fix — nav-invariant shell)
//
// `ContentView` is the SHELL: it composes `SidebarPane` / `ContentPane` /
// `DetailPane` into the `NavigationSplitView`, owns the two observable state
// models as `@State` (injected via `.environment`), and hosts the app
// bootstrap + key handlers + menu-command publication.
//
// THE LOAD-BEARING RULE (the #146 diagnosis' fix): this body NEVER reads a
// property of `nav` / `unreadState` and never projects `@Bindable` — a view
// forms an Observation dependency only when its BODY reads a tracked
// property; holding or passing the reference does not
// (`developer.apple.com/documentation/swiftui/managing-model-data-in-your-app`,
// `developer.apple.com/documentation/swiftui/state` → "Create property
// bindings with @Bindable", `developer.apple.com/documentation/swiftui/bindable`).
// Every model access below lives inside a CLOSURE (key handlers, actions,
// preference/onChange handlers) — executed at call time, invisible to body's
// dependency tracking. The grep audit in the PR pins this shape.
//
// Residual body dependencies (accepted, named in the PR): `needsSetup`
// (onboarding sheet), `panelFocus` (focus routing), `scenePhase`.

// MARK: - Content View

struct ContentView: View {
  /// Entry count seeded for the headless reading state (#141). Small so the
  /// automated-launch host boots fast, but enough rows across the perf
  /// seeder's twelve categories to render a real three-pane reading state.
  private static let headlessSeedEntryCount = 120

  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(\.modelContext)
  private var modelContext
  @Environment(\.scenePhase)
  private var scenePhase
  /// Navigation state owner (issue #146 final fix): selection, article
  /// selection + memo, filter, view mode, taxonomy mirrors. Held here as
  /// `@State`, READ only by the panes.
  @State
  private var nav = ReadingSelection()
  /// Unread universe owner: snapshot, pending-read overlay, refresh version,
  /// rendered-entries payload. Held here as `@State`, READ only by the panes.
  @State
  private var unreadState = UnreadState()
  /// App-lifetime favicon cache (issue #148): decoded once per feed off the
  /// render path, injected into the environment for `EntryListView`.
  @State
  private var faviconStore = FaviconStore()
  @State
  private var needsSetup = false
  @FocusState
  private var panelFocus: PanelFocus?
  private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
  private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
  private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }
  private var isPerfScenarioMode: Bool { PerfScenarioRunner.isEnabled }

  var body: some View {
    NavigationSplitView {
      SidebarPane(
        panelFocus: $panelFocus,
        onMarkAllRead: markAllAsRead,
        onSyncAndClassify: { Task { await syncAndClassify() } }
      )
    } content: {
      ContentPane(
        panelFocus: $panelFocus,
        flushPendingReads: flushPendingReads,
        onMarkAllRead: markAllAsRead
      )
    } detail: {
      DetailPane(
        onMarkAllRead: markAllAsRead,
        onToggleViewMode: toggleArticleViewMode,
        onOpenInBrowser: openInBackground
      )
    }
    .environment(nav)
    .environment(unreadState)
    .environment(faviconStore)
    .environment(\.bareKeyActions, bareKeyActions)
    .onAppear {
      checkCredentials()
      nav.revalidateSelection()
      panelFocus = .sidebar
    }
    // WebKit preheat — issue #106. `.task` runs after the root view appears
    // (Apple's docs: "before this view appears", with the closure executing
    // once on appearance — not an idle-frame defer), so the warm fires
    // before the user can plausibly click an article but after SwiftUI has
    // committed the first render. `.utility` priority keeps the warm call
    // below user-initiated work that may be running concurrently; the warm
    // itself is a single synchronous MainActor call (it touches WKWebView,
    // which is MainActor-only) inside an async context so SwiftUI's `.task`
    // lifecycle can cancel it cleanly if the view tears down before
    // completion. Idempotent — re-attached views (Settings reopen, etc.)
    // are no-ops.
    .task(priority: .utility) {
      // Skip the preheat under headless mode: WKWebView's GPU/Web processes
      // are unstable in the sandboxed headless host and crash long
      // unattended runs. `WebKitPreheatTests` call `warmIfNeeded()`
      // directly, so this gate does not affect their coverage (#141).
      if !HeadlessMode.isEnabled { WebKitPreheat.warmIfNeeded() }
    }
    .sheet(isPresented: $needsSetup) {
      OnboardingView {
        needsSetup = false
        startSync()
      }
      .environment(syncEngine)
    }
    .onChange(of: scenePhase) {
      if scenePhase != .active {
        flushPendingReads()
        Task { await syncEngine.pushPendingReads() }
      }
    }
    // Escape and Tab stay at NavigationSplitView level — not consumed by
    // List type-to-select. Letter keys (J/K/R/B) have handlers on each
    // panel's List via BareKeyHandler AND here as fallback for when no List
    // has focus (e.g. after programmatic selection change).
    .onKeyPress(.escape) {
      nav.selectedEntryID = nil
      panelFocus = .sidebar
      return .handled
    }
    .onKeyPress(.tab) {
      switch panelFocus {
      case .sidebar, .none:
        tabIntoArticleList()
      case .articleList:
        panelFocus = .sidebar
      }
      return .handled
    }
    // Why dual-route: the per-panel `BareKeyHandler` modifiers ensure J/K/R/B
    // do NOT trigger while the user is typing in a text field (search,
    // password editor, etc.) — only when a List has focus. This fallback
    // covers the gap after programmatic selection changes when no List
    // currently owns focus. Revisit only if SwiftUI focus APIs make a single
    // `.focusState`-driven route viable.
    .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in bareKeyActions.onJ() }
    .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in bareKeyActions.onK() }
    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in bareKeyActions.onR() }
    .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in bareKeyActions.onB() }
    .modifier(menuBarValues)
  }

  // MARK: - Menu-command publication (references + closures — no reads)

  /// Publishes the command context. The context carries REFERENCES and
  /// action closures only (issue #146): enablement booleans are computed
  /// INSIDE the `FeederCommands` scene body from the nav model, so this
  /// shell never reads navigation state to publish them.
  private var menuBarValues: some ViewModifier {
    FocusedValuesModifier(
      context: FeederCommandContext(
        nav: nav,
        syncEngine: syncEngine,
        classificationEngine: classificationEngine,
        syncAction: { Task { await syncAndClassify() } },
        markAllReadAction: markAllAsRead,
        toggleViewModeAction: toggleArticleViewMode,
        openInBrowserAction: openInBackground,
        moveSelectionDownAction: { nav.moveSelection(by: 1) },
        moveSelectionUpAction: { nav.moveSelection(by: -1) }
      )
    )
  }

  /// J/K/R/B fallback actions — every model access is inside a closure
  /// (call-time, no body dependency). J/K route through the nav model's
  /// mirror-backed `moveSelection`, so a keystroke reads zero `@Model` rows.
  private var bareKeyActions: BareKeyActions {
    BareKeyActions(
      onJ: {
        nav.moveSelection(by: 1)
        panelFocus = .sidebar
        return .handled
      },
      onK: {
        nav.moveSelection(by: -1)
        panelFocus = .sidebar
        return .handled
      },
      onR: {
        guard nav.selectedEntry != nil else { return .ignored }
        toggleArticleViewMode()
        return .handled
      },
      onB: {
        guard nav.selectedEntry != nil else { return .ignored }
        openInBackground()
        return .handled
      }
    )
  }

  // MARK: - Actions

  private func toggleArticleViewMode() {
    nav.articleViewMode = nav.articleViewMode == .web ? .reader : .web
  }

  private func flushPendingReads() {
    let ids = unreadState.pendingReadIDs
    guard !ids.isEmpty else { return }
    syncEngine.queueReadIDs(ids)
    Task {
      guard let writer = syncEngine.writer else { return }
      try? await writer.markEntriesRead(feedbinEntryIDs: ids)
      // Locally mutating isRead invalidates the article-list snapshot —
      // refetch so the unread filter shrinks. Without this, scrubbed-past
      // entries linger (only dimmed via the overlay) until the next
      // sync/classification. The matching overlay IDs are pruned by
      // `UnreadState.prune()` once the refetched sources confirm the save;
      // draining eagerly here would race the merge and could briefly bump
      // the sidebar counts back up.
      unreadState.noteDataChanged()
    }
  }

  private func markAllAsRead() {
    // Sidebar `selection` is both what the user sees and the source of truth
    // for the article-list column — no separate "rendered" mirror to consult.
    guard nav.articleFilter == .unread, let target = nav.selection,
      let writer = syncEngine.writer
    else { return }
    nav.selectedEntryID = nil
    let markTarget = unreadState.markAllOptimistically(target: target)
    Task {
      let markedIDs = try? await writer.markAllAsRead(
        target: markTarget, cutoffDate: syncEngine.queryCutoffDate
      )
      // Same rationale as flushPendingReads — refetch so the now-empty
      // unread list (or the remaining unread items) appears immediately.
      unreadState.noteDataChanged()
      guard let ids = markedIDs, !ids.isEmpty else { return }
      syncEngine.queueReadIDs(ids)
    }
  }

  private func openInBackground() {
    guard let entry = nav.selectedEntry,
      let url = URL(string: entry.url),
      let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
    else { return }
    NSWorkspace.shared.open(
      [url],
      withApplicationAt: appURL,
      configuration: {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        return config
      }()
    )
  }

  /// Tab from sidebar into the article-list column. Selecting the first row
  /// is gated on the rendered payload being non-empty, which is only true
  /// once the article list has rendered for the active selection. No
  /// selection or no rendered list ⇒ Tab moves focus only. The one
  /// live-model materialization happens in the single-writer resolve.
  /// (Cut 2: reads the model's payload — a call-time closure read; the
  /// shell no longer mirrors it in `@State`.)
  private func tabIntoArticleList() {
    panelFocus = .articleList
    guard let firstID = unreadState.visibleEntries.ids.first else { return }
    nav.selectedEntryID = firstID
  }

  // MARK: - Helpers

  private func checkCredentials() {
    if isPerfScenarioMode {
      runPerfScenario()
      return
    }
    if HeadlessMode.isEnabled {
      bootHeadless()
      return
    }
    if isPreviewMode {
      // Preview canvases seed their model container directly and never run
      // `startSync`/`configure`, so `syncEngine.writer` stays nil and
      // `EntryListView` would otherwise spin on `ProgressView` forever.
      // Attach a writer so the preview renders its seeded rows.
      let container = modelContext.container
      Task {
        let writer = await DataWriter.makeDetached(modelContainer: container)
        let reader = await DataReader.makeDetached(modelContainer: container)
        syncEngine.attachWriter(writer)
        syncEngine.attachReader(reader)
      }
      return
    }
    if isUITestForceOnboarding {
      needsSetup = true
      return
    }
    if isUITestDemoMode {
      seedUITestDataIfNeeded()
      return
    }

    let username = UserDefaults.standard.string(forKey: feedbinUsernameUserDefaultsKey) ?? ""
    let password = KeychainHelper.load(key: KeychainHelper.feedbinPasswordKey) ?? ""
    if username.isEmpty || password.isEmpty {
      needsSetup = true
    } else {
      // Pass the already-loaded password through so `startSync` does not
      // trigger a second keychain consent prompt for the same item on
      // first launch after install (#99).
      startSync(username: username, password: password)
    }
  }

  /// Boot the self-contained headless reading state (#141). Attaches a
  /// writer / reader on the app's (in-memory) container, installs an inert
  /// Feedbin client so no sync can reach the network, seeds the perf fixture
  /// so the three panes render a real reading state, and selects the first
  /// folder.
  ///
  /// Crucially this returns from `checkCredentials` BEFORE any
  /// `KeychainHelper.load`, `needsSetup`, or `startSync` — so an automated
  /// launch never triggers a macOS Keychain consent prompt, shows onboarding,
  /// or contacts Feedbin. The store is already in-memory (`FeederApp.init`
  /// gated on the same `HeadlessMode.isEnabled`), so this reading state never
  /// touches the user's real on-disk data.
  private func bootHeadless() {
    let container = modelContext.container
    // Defence in depth: attach an inert client so any future/accidental sync
    // path cannot reach Feedbin. Headless boot never starts periodic sync.
    syncEngine.attachClient(InertFeedbinClient())
    Task {
      let writer = await DataWriter.makeDetached(modelContainer: container)
      let reader = await DataReader.makeDetached(modelContainer: container)
      syncEngine.attachWriter(writer)
      syncEngine.attachReader(reader)
      // Reuse the perf seeder: every entry gets exactly one category and rows
      // are strictly newest-first, honouring the `VISION.md` invariants.
      _ = try? await writer.seedPerfTestData(entryCount: Self.headlessSeedEntryCount)
      if nav.selection == nil {
        nav.selection = .folder("technology")
      }
    }
  }

  /// Drive the headless perf scenario. Attaches a `DataWriter` so
  /// `EntryListView` can render the seeded rows, then hands control to
  /// `PerfScenarioRunner`, which mutates the nav model on MainActor — the
  /// same writes the user would make. `exit(0)` inside the runner ends the
  /// launch so `xctrace` finalises the recorded trace.
  private func runPerfScenario() {
    let container = modelContext.container
    Task { @MainActor in
      let writer = await DataWriter.makeDetached(modelContainer: container)
      // Read-only companion: a separate actor with a 2nd read-only context on
      // the SAME container (option (i)). A single perf instance is low
      // concurrency, so the shared context is safe here.
      let reader = await DataReader.makeDetached(modelContainer: container)
      syncEngine.attachWriter(writer)
      syncEngine.attachReader(reader)
      await PerfScenarioRunner.run(
        writer: writer,
        syncEngine: syncEngine,
        apply: { newSelection, newEntryID, newMode in
          nav.selection = newSelection
          nav.selectedEntryID = newEntryID
          nav.articleViewMode = newMode
        },
        visibleEntryIDs: {
          // The runner picks the first visible row to click; selection is
          // ID-typed (issue #148), so no Entry materialization is needed
          // here — the single-writer resolve handles it.
          unreadState.visibleEntries.ids
        },
        navigate: { direction in
          // Route through the real J/K handler. Post-#146 this pays the
          // mirror-backed `moveSelection` + `panelFocus` resolution — the
          // per-keystroke `@Query` recompute is gone BY DESIGN (that removal
          // is part of the fix under measurement).
          switch direction {
          case .next: _ = bareKeyActions.onJ()
          case .previous: _ = bareKeyActions.onK()
          }
        },
        bumpEntryList: { unreadState.noteDataChanged() },
        currentSelection: { nav.selection }
      )
    }
  }

  private func seedUITestDataIfNeeded() {
    let container = modelContext.container
    Task {
      // Build the writer via the shared helper so `EntryListView` can
      // render the seeded rows (without a writer the demo-mode launch
      // sticks on `ProgressView`).
      let writer = await DataWriter.makeDetached(modelContainer: container)
      let reader = await DataReader.makeDetached(modelContainer: container)
      syncEngine.attachWriter(writer)
      syncEngine.attachReader(reader)
      _ = try? await writer.seedUITestData()
      // Select the demo fixture's first folder whether this launch seeded
      // fresh or reuses an earlier seed (the pre-split code read
      // `folders.first` synchronously for the reuse case; the seeded folder
      // set is fixed, so the label is equivalent).
      if nav.selection == nil {
        nav.selection = .folder("technology")
      }
    }
  }

  /// Start (or resume) periodic Feedbin sync.
  ///
  /// On cold launch `checkCredentials()` has already loaded the username /
  /// password from `UserDefaults` / Keychain and passes them through to
  /// avoid a second `SecItemCopyMatching` call — and therefore a second
  /// system Keychain consent prompt for the same item — on the very first
  /// launch after install (#99). The onboarding-completion call site (where
  /// credentials were just written milliseconds ago and the Keychain ACL
  /// allows silent reads) keeps the no-argument form.
  private func startSync(
    username preloadedUsername: String? = nil, password preloadedPassword: String? = nil
  ) {
    let username =
      preloadedUsername ?? UserDefaults.standard.string(forKey: feedbinUsernameUserDefaultsKey)
      ?? ""
    let password =
      preloadedPassword ?? KeychainHelper.load(key: KeychainHelper.feedbinPasswordKey) ?? ""
    guard !username.isEmpty, !password.isEmpty else { return }

    // `FeederApp.runBootstrap()` has already attached the production writer
    // before this view renders, so we only configure credentials here.
    syncEngine.configure(username: username, password: password)

    Task {
      // Purge entries older than the 30-day ceiling (`maxRetentionAge`).
      // Disk-retention cleanup is belt-and-suspenders: `fetchEntrySections`
      // and `fetchUnreadCountsSnapshot` already filter on `publishedAt >=
      // cutoffDate`, so purged rows never appear in the UI even before the
      // next refresh, but without the purge the store grows unboundedly.
      // The writer owns the day-count math; the call site passes the
      // ceiling derived from `maxRetentionAge` so toggling the
      // `articleKeepDays` setting between 1 and 30 never requires a
      // refetch + recategorise round-trip.
      if let writer = syncEngine.writer {
        let days = Int(maxRetentionAge / 86_400)
        _ = try? await writer.purgeEntriesOlderThan(days)
      }

      let syncInterval = UserDefaults.standard.double(forKey: syncIntervalUserDefaultsKey)
        .clamped(to: 60...3600, default: 300)
      syncEngine.startPeriodicSync(interval: syncInterval)
      if let writer = syncEngine.writer {
        classificationEngine.startContinuousClassification(writer: writer)
      }
    }
  }

  private func syncAndClassify() async {
    await syncEngine.sync()
    if let writer = syncEngine.writer {
      await classificationEngine.classifyUnclassified(writer: writer)
    }
  }
}

// MARK: - Preview

#Preview("Timeline - Seeded Demo") {
  timelineSeededDemoPreview()
}

@MainActor
private func timelineSeededDemoPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let techFolder = Folder(label: "technology", displayName: "Technology", sortOrder: 0)
  context.insert(techFolder)

  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple preview", sortOrder: 0,
    folderLabel: "technology")
  let world = Category(
    label: "world_news", displayName: "World News",
    categoryDescription: "World coverage for preview", sortOrder: 0)
  context.insert(apple)
  context.insert(world)

  let feed1 = Feed(
    feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "The Verge",
    feedURL: "https://theverge.com/rss",
    siteURL: "https://theverge.com", createdAt: .now)
  context.insert(feed1)

  for i in 1...5 {
    let entry = Entry(
      feedbinEntryID: i, title: "Sample Tech Story \(i)", author: "Feeder Bot",
      url: "https://example.com/\(i)",
      content: "<p>Sample article \(i).</p>", summary: "Sample \(i)", extractedContentURL: nil,
      publishedAt: .now.addingTimeInterval(-Double(i) * 900),
      createdAt: .now.addingTimeInterval(-Double(i) * 850))
    entry.feed = feed1
    entry.primaryCategory = "apple"
    entry.primaryFolder = "technology"
    entry.isClassified = true
    entry.isRead = i > 3
    entry.formattedDate = "Today, \(i)th Mar, 12:0\(i)"
    entry.plainText = "Sample article \(i)."
    context.insert(entry)
  }

  try? context.save()

  return ContentView()
    .environment(SyncEngine())
    .environment(ClassificationEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(minWidth: 1200, minHeight: 760)
}
