import Foundation
import SwiftData
import SwiftUI
import os.signpost

// MARK: - Content View root
//
// `EntryListView`, `SyncStatusView`, and the sidebar/key-handling helpers
// live in dedicated files — see `Views/EntryListView.swift`,
// `Views/SyncStatusView.swift`, and `Views/Support/*`. ContentView stays
// focused on the NavigationSplitView layout, selection debouncing, sync
// bootstrap, and menu-bar action wiring.

// MARK: - Content View

struct ContentView: View {
  /// Hold time before a finished classification batch is allowed to refresh the
  /// article list while the user is actively browsing. Bumping
  /// `entryRefreshVersion` causes `EntryListView` to re-fetch sections; if any
  /// row gained or lost a category in that batch, the `List` rebuilds and may
  /// reseat its scroll anchor around the selected row — the user perceives
  /// this as the list "jumping" when they were just scrolling/clicking. We
  /// defer the bump until the user's selection has been stable for this long
  /// (or selection clears) so the refresh lands at a quiet moment.
  fileprivate static let classificationBumpDwell: Duration = .seconds(4)
  /// Idle throttle for classification bumps when no row is selected. The
  /// no-selection drain used to be immediate; while the user watches a
  /// still-empty (or just-filling) category, classification progress ticks
  /// would each trigger a full re-fetch. One second coalesces the ticks into
  /// a calm live-populate cadence without delaying the first row noticeably
  /// (issue #146). The 4 s selection dwell above is untouched.
  fileprivate static let classificationIdleThrottle: Duration = .seconds(1)
  /// Shorter dwell for sync-page bumps. New entries persisted by a sync page
  /// land at the top of the list via stable-ID diffing — `List` preserves the
  /// scroll anchor around the selected row, so a near-immediate refresh stays
  /// non-disruptive. The dwell still buys a small coalescing window so a
  /// burst of pages collapses into one re-fetch instead of N. Also passed as
  /// the sync channel's no-selection `idleThrottle` (issue #146) so a page
  /// burst coalesces there too, replacing the previous immediate drain.
  fileprivate static let syncBumpDwell: Duration = .milliseconds(750)
  /// Entry count seeded for the headless reading state (#141). Small so the
  /// automated-launch host boots fast, but enough rows across the perf seeder's
  /// twelve categories to render a real three-pane reading state.
  private static let headlessSeedEntryCount = 120

  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(\.modelContext)
  private var modelContext
  @Environment(\.scenePhase)
  private var scenePhase
  @Query(sort: \Folder.sortOrder)
  private var folders: [Folder]
  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]
  /// Root-level categories fetched via a SQLite-level predicate. Replaces an
  /// `allCategories.atRoot` in-memory filter on every render.
  @Query(filter: #Predicate<Category> { $0.folderLabel == nil }, sort: \Category.sortOrder)
  private var rootCategories: [Category]
  /// Cached aggregation over the classified-unread universe. Refreshed by
  /// `unreadSnapshotRefreshTask` whenever `entryRefreshVersion` or the
  /// taxonomy structure changes — never re-fetched inside body. Replaces a
  /// `@Query unreadEntries` that fired a full SQLite fetch + per-row property
  /// access during every body re-eval (33.8% of main-thread CPU in the
  /// 2026-05 Time Profiler trace).
  @State
  private var unreadSnapshot: UnreadCountsSnapshot = .empty
  @AppStorage("sidebar.collapsedFolders")
  private var collapsedFolders: SidebarCollapsedFolders = .init()
  /// Source of truth for the article-list selection (issue #148): the row
  /// DTO's `PersistentIdentifier`, written by the `List` selection binding,
  /// Tab-into-list, the Escape / filter / sidebar clears, mark-all-read, and
  /// the perf runner.
  @State
  private var selectedEntryID: PersistentIdentifier?
  /// Memoized live model for the selected row — the ONE full `Entry`
  /// materialization per selection (detail pane, open-in-browser, mark-read,
  /// drain keys, pinned-row id). SINGLE-WRITER discipline: written in EXACTLY
  /// ONE place, the `.onChange(of: selectedEntryID)` handler; every other
  /// consumer only reads it. Do not assign it anywhere else.
  @State
  private var selectedEntry: Entry?
  @State
  private var selection: SidebarSelection?
  @State
  private var articleFilter: ArticleFilter = .unread
  @State
  private var articleViewMode: ArticleViewMode = .web
  @State
  private var needsSetup = false
  @State
  private var pendingReadIDs: Set<Int> = []
  /// Rendered-entries payload bubbled up from `EntryListView` — the visible
  /// ids (Tab-into-list) plus the rendered-unread ids (one side of the
  /// two-sided `pendingReadIDs` retention prune, issue #148).
  @State
  private var currentEntries: VisibleEntriesPayload = .empty
  /// App-lifetime favicon cache (issue #148): decoded once per feed off the
  /// render path, injected into the environment for `EntryListView`.
  @State
  private var faviconStore = FaviconStore()
  /// Bumped whenever underlying article data may have changed (sync completed,
  /// classification batch finished). `EntryListView` includes this in its
  /// `.task(id:)` key, triggering a re-fetch — replaces SwiftData's `@Query`
  /// auto-refresh now that the article list is fetched off MainActor.
  /// All mutations bump via `bumpEntryList()` to keep a single point of accountability.
  @State
  private var entryRefreshVersion: Int = 0
  /// Set true when classification finishes a batch and a refresh is owed; drained
  /// by the dwell task below once the user's selection has been stable. Keeps
  /// background refreshes from yanking the article list while the user clicks
  /// or scrolls.
  @State
  private var pendingClassificationBump = false
  /// Set true when a sync page lands and a mid-sync refresh is owed; drained
  /// by a shorter-dwell sibling of `pendingClassificationBump` so newly-
  /// persisted entries appear in the middle pane as pages arrive, without
  /// waiting for the terminal `isSyncing` false-edge.
  @State
  private var pendingSyncBump = false
  @FocusState
  private var panelFocus: PanelFocus?
  /// In-flight click → render signpost states. Held in `@State` so the begin
  /// (fired from `.onChange`) survives across the SwiftUI commit boundary to
  /// the matching end (fired from `.task(id:)` on the next render pass). See
  /// `PerformanceSignposts.swift` for the `OSSignposter` itself.
  @State
  private var sidebarClickIntervalState: OSSignpostIntervalState?
  @State
  private var articleClickIntervalState: OSSignpostIntervalState?
  /// `contentViewReeval` interval state + its render-pass token (issue #146,
  /// DIAGNOSTIC-ONLY): begins when a `VisibleEntriesKey` payload arrives, ends on
  /// the next ContentView render pass via `.task(id: contentReevalVersion)` —
  /// measuring the whole-split-view re-eval a full-N preference triggers.
  @State
  private var contentReevalIntervalState: OSSignpostIntervalState?
  @State
  private var contentReevalVersion = 0
  private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
  private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
  private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }
  private var isPerfScenarioMode: Bool { PerfScenarioRunner.isEnabled }
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    NavigationSplitView {
      sidebarView
        .focused($panelFocus, equals: .sidebar)
    } content: {
      if let selection {
        entryListForSelection(selection)
          .focused($panelFocus, equals: .articleList)
          .environment(\.pendingReadIDs, pendingReadIDs)
          .navigationTitle(navigationTitle)
          .toolbar {
            ToolbarItem(placement: .automatic) {
              Picker("Filter", selection: $articleFilter) {
                ForEach(ArticleFilter.allCases, id: \.self) { filter in
                  Text(filter.rawValue).tag(filter)
                }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .accessibilityIdentifier("article.filter")
            }
            ToolbarItem(placement: .automatic) {
              Button {
                markAllAsRead()
              } label: {
                Image(systemName: "checkmark")
              }
              .disabled(articleFilter == .read)
              .help("Mark all as read (⇧A)")
              .accessibilityIdentifier("toolbar.markAllRead")
            }
          }
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: articleFilter)
      } else {
        ContentUnavailableView {
          Label("No Category", systemImage: "newspaper")
        } description: {
          Text("Select a category from the sidebar.")
        }
      }
    } detail: {
      detailView
    }
    .environment(\.bareKeyActions, bareKeyActions)
    .environment(faviconStore)
    .onPreferenceChange(VisibleEntriesKey.self) { payload in
      // Sub-cost split (issue #146, diagnostic): open the reeval interval before
      // the @State writes below dirty ContentView; the paired end fires on the
      // next render pass via `.task(id: contentReevalVersion)`.
      contentReevalIntervalState = perfSignposter.beginInterval(
        PerformanceSignpostName.contentViewReeval
      )
      contentReevalVersion &+= 1
      currentEntries = payload
      // Second prune trigger (issue #148): the rendered-unread side of the
      // two-sided retention criterion just changed — re-evaluate the overlay
      // so an ID whose refetched DTO confirms `isRead == true` on BOTH sides
      // is released here, not only on the next snapshot refresh.
      prunePendingReadIDs()
    }
    .task(id: contentReevalVersion) {
      // Sub-cost split (issue #146, diagnostic): close the reeval interval on
      // the render pass that followed the preference-driven @State writes.
      guard let state = contentReevalIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.contentViewReeval, state)
      contentReevalIntervalState = nil
    }
    .onAppear {
      checkCredentials()
      revalidateSelection()
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
      // Skip the preheat under headless mode: WKWebView's GPU/Web processes are
      // unstable in the sandboxed headless host and crash long unattended runs.
      // `WebKitPreheatTests` call `warmIfNeeded()` directly, so this gate does
      // not affect their coverage (#141).
      if !HeadlessMode.isEnabled { WebKitPreheat.warmIfNeeded() }
    }
    .sheet(isPresented: $needsSetup) {
      OnboardingView {
        needsSetup = false
        startSync()
      }
      .environment(syncEngine)
    }
    .onChange(of: selectedEntryID) { _, newID in
      // SINGLE WRITER for `selectedEntry` (issue #148): resolve the one live
      // model per selection commit here — an O(1) primary-key lookup for
      // exactly one row, at the interface↔store boundary. Every other
      // consumer (detail pane, drain keys, open-in-browser, pinned-row id)
      // reads the memoized @State.
      let newEntry = newID.flatMap { modelContext.model(for: $0) as? Entry }
      selectedEntry = newEntry
      // Defer the pending-read insertion off the selection-commit critical
      // path. An in-frame mutation would cascade through the sidebar
      // unread-count aggregation and the EntryRowView dimming overlay
      // (both observe `pendingReadIDs`), nudging row metrics on the same
      // frame the user pressed arrow-down — perceived as keyboard lag.
      // `applyPendingReadAfterYield` yields the selection write first,
      // then mutates next tick. Mark-read reads the LIVE `entry.isRead` —
      // fresher than the row DTO's snapshot.
      if let entry = newEntry, !entry.isRead {
        applyPendingReadAfterYield(feedbinEntryID: entry.feedbinEntryID) { id in
          pendingReadIDs.insert(id)
        }
      }
      articleViewMode = .web
      // Article-click signpost begin: measures SwiftUI commit cost from
      // writing the selection to the detail column's `.task` firing.
      // No begin when selection clears — empty-state has no render cost.
      if newEntry != nil {
        articleClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.articleClick
        )
      }
    }
    .task(id: selectedEntry?.feedbinEntryID) {
      // Article-click signpost end: pairs with the begin in
      // `.onChange(of: selectedEntry)`. Runs immediately, no sleep — the
      // dwell that used to live here is gone (see commit dropping
      // renderDwell). Closing the interval here keeps the measurement
      // bounded to "selection commit ⇒ next SwiftUI render pass".
      guard let state = articleClickIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.articleClick, state)
      articleClickIntervalState = nil
    }
    .onChange(of: articleFilter) {
      flushPendingReads()
      selectedEntryID = nil
    }
    .onChange(of: selection) { _, newSelection in
      flushPendingReads()
      selectedEntryID = nil
      // Sidebar-click signpost begin: measures SwiftUI commit cost from
      // writing `selection` to the content column re-rendering.
      if newSelection != nil {
        sidebarClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.sidebarClick
        )
      }
    }
    .task(id: selection) {
      // Sidebar-click signpost end: pairs with the begin in
      // `.onChange(of: selection)`. Same shape as the article-click end —
      // runs immediately on the next render pass and closes the interval.
      guard let state = sidebarClickIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.sidebarClick, state)
      sidebarClickIntervalState = nil
    }
    .onChange(of: allCategories.count) {
      revalidateSelection()
    }
    .onChange(of: folders.count) {
      revalidateSelection()
    }
    .onChange(of: scenePhase) {
      if scenePhase != .active {
        flushPendingReads()
        Task { await syncEngine.pushPendingReads() }
      }
    }
    // Refresh the cached unread snapshot whenever the underlying data may
    // have changed. The modifier owns the `.task(id:)` so the body stays
    // inside SwiftUI's type-checker budget.
    .modifier(
      UnreadSnapshotRefreshTask(
        key: unreadSnapshotKey,
        reader: syncEngine.reader,
        cutoffDate: syncEngine.queryCutoffDate,
        snapshot: $unreadSnapshot
      )
    )
    // Keep `pendingReadIDs` aligned with the live unread snapshot: when a
    // background write (mark-read / mark-all-read / sync) flips entries out
    // of the snapshot, drop their IDs from the optimistic overlay so the
    // set does not grow unbounded across a long session and does not mask a
    // future cross-device unread flip on the same ID.
    .modifier(
      PendingReadPruneTrigger(
        unreadCount: unreadSnapshot.totalUnread,
        onUnreadCountChange: { prunePendingReadIDs() }
      )
    )
    // Refresh the article list (re-fires `EntryListView.task`) whenever
    // underlying article data may have changed. Replaces SwiftData's
    // `@Query` auto-refresh now that the list is fetched off MainActor.
    // Both triggers fire on the false transition (work just finished), and
    // only when the batch that just finished actually changed rows — sync
    // counts inserts plus cross-device read-state flips so the article list
    // stays in step with the sidebar unread counts when a user marks
    // articles read on another device; classification counts rows that got
    // a fresh category assignment. A quiet tick with zero changes leaves
    // the list untouched so the refresh task does not re-fetch for nothing.
    .onChange(of: syncEngine.isSyncing) { _, isSyncing in
      if !isSyncing && syncEngine.lastSyncChangedEntryCount > 0 {
        bumpEntryList()
      }
    }
    .onChange(of: classificationEngine.isClassifying) { _, isClassifying in
      if !isClassifying && classificationEngine.lastBatchClassifiedCount > 0 {
        pendingClassificationBump = true
      }
    }
    // Mid-flight refresh signals: bumped while the underlying job is still
    // running. Sync bumps once per persisted page; classification bumps once
    // per throttled (200 ms) progress snapshot. Both route into the deferred
    // drain channel so a burst of bumps coalesces into a single
    // `entryRefreshVersion` tick that `EntryListView.task(id:)` consumes —
    // selection and scroll position are preserved by `List`'s stable-ID
    // diffing in `EntryListView.reload()`.
    //
    // `MidFlightBumpRouter` is a leaf `View` (not a `ViewModifier`) so the
    // `syncEngine.lastPersistedPageVersion` / `classificationEngine
    // .batchProgressVersion` reads live inside its own body, not
    // `ContentView.body`. Without this hoisting, every sync page (~1 Hz)
    // and every classification progress tick (~5 Hz) would invalidate
    // `ContentView.body` and re-trigger the sidebar/snapshot derivations.
    // The leaf is mounted as an invisible `.background` sibling via
    // `MidFlightBumpRouterModifier` so the body chain stays a single
    // `.modifier(...)` line — type-checker friendly.
    .modifier(
      MidFlightBumpRouterModifier(
        pendingSyncBump: $pendingSyncBump,
        pendingClassificationBump: $pendingClassificationBump
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: classificationBumpDrainKey,
        dwell: Self.classificationBumpDwell,
        idleThrottle: Self.classificationIdleThrottle,
        hasSelection: selectedEntry != nil,
        pendingBump: $pendingClassificationBump,
        onDrain: { bumpEntryList() }
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: syncBumpDrainKey,
        dwell: Self.syncBumpDwell,
        idleThrottle: Self.syncBumpDwell,
        hasSelection: selectedEntry != nil,
        pendingBump: $pendingSyncBump,
        onDrain: { bumpEntryList() }
      )
    )
    .modifier(
      CategoryFolderChangeTrigger(
        categoryFolderLabels: categoryFolderLabels,
        onChange: { bumpEntryList() }
      )
    )
    // Escape and Tab stay at NavigationSplitView level — not consumed by List type-to-select.
    // Letter keys (J/K/R/B) have handlers on each panel's List via BareKeyHandler AND here
    // as fallback for when no List has focus (e.g. after programmatic selection change).
    .onKeyPress(.escape) {
      selectedEntryID = nil
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

  // Separated to keep body type-checkable
  private var menuBarValues: some ViewModifier {
    FocusedValuesModifier(
      context: FeederCommandContext(
        syncAction: { Task { await syncAndClassify() } },
        markAllReadAction: markAllAsRead,
        toggleViewModeAction: toggleArticleViewMode,
        openInBrowserAction: openInBackground,
        moveSelectionDownAction: { moveSidebarSelection(by: 1) },
        moveSelectionUpAction: { moveSidebarSelection(by: -1) },
        canMarkAllRead: articleFilter == .unread && selection != nil,
        canOpenInBrowser: selectedEntry != nil,
        hasSelectedEntry: selectedEntry != nil,
        isSyncing: syncEngine.isSyncing || classificationEngine.isClassifying,
        currentViewMode: articleViewMode
      )
    )
  }

  // MARK: - Category lookups (small count, acceptable in-memory filter)

  /// Filter+sort the folder list down to those with at least one category,
  /// paired with their categories. Called from both `sidebarView` (hoisted to
  /// a `let` so the body sees a single value) and `sidebarItems` (re-evaluated
  /// per J/K keystroke for keyboard nav). Each invocation runs
  /// `allCategories.inFolder(...)` once per folder — the two call sites do
  /// not share a single computation; the property packages the dedupe
  /// against `inFolder(...)` being called twice in one render pass.
  private var visibleFolderGroups: [(folder: Folder, categories: [Category])] {
    folders.compactMap { folder in
      let categoriesInFolder = allCategories.inFolder(folder.label)
      guard !categoriesInFolder.isEmpty else { return nil }
      return (folder, categoriesInFolder)
    }
  }

  /// Flat ordered sidebar items matching the keyboard-visible navigation order.
  /// Folders with no categories are skipped entirely; a folder's child rows are
  /// included only when the folder is currently expanded — otherwise J/K would
  /// land on rows that are not visible in the source list. Delegates to the
  /// pure `sidebarNavigationItems(...)` helper so the same rules apply in tests.
  private var sidebarItems: [SidebarSelection] {
    let groups = visibleFolderGroups.map { group in
      (folderLabel: group.folder.label, categoryLabels: group.categories.map(\.label))
    }
    return sidebarNavigationItems(
      folderGroups: groups,
      rootCategoryLabels: rootCategories.map(\.label),
      collapsedFolderLabels: collapsedFolders.labels
    )
  }

  private func moveSidebarSelection(by offset: Int) {
    let items = sidebarItems
    guard !items.isEmpty else { return }
    guard let current = selection, let index = items.firstIndex(of: current) else {
      selection = offset > 0 ? items.first : items.last
      return
    }
    let newIndex = min(max(index + offset, 0), items.count - 1)
    selection = items[newIndex]
  }

  private func toggleArticleViewMode() {
    articleViewMode = articleViewMode == .web ? .reader : .web
  }

  private var bareKeyActions: BareKeyActions {
    BareKeyActions(
      onJ: {
        moveSidebarSelection(by: 1)
        panelFocus = .sidebar
        return .handled
      },
      onK: {
        moveSidebarSelection(by: -1)
        panelFocus = .sidebar
        return .handled
      },
      onR: {
        guard selectedEntry != nil else { return .ignored }
        toggleArticleViewMode()
        return .handled
      },
      onB: {
        guard selectedEntry != nil else { return .ignored }
        openInBackground()
        return .handled
      }
    )
  }

  @ViewBuilder
  private func entryListForSelection(_ sel: SidebarSelection) -> some View {
    if let reader = syncEngine.reader {
      let (category, folder): (String?, String?) =
        switch sel {
        case .category(let label): (label, nil)
        case .folder(let label): (nil, label)
        }
      EntryListView(
        category: category, folder: folder, filter: articleFilter,
        cutoffDate: syncEngine.queryCutoffDate, reader: reader,
        refreshVersion: entryRefreshVersion,
        pinnedFeedbinEntryID: selectedEntry?.feedbinEntryID,
        selectedEntryID: $selectedEntryID, onMarkAllRead: markAllAsRead
      )
    } else {
      // SyncEngine.configure hasn't completed yet (first launch path).
      // The .toolbar, .navigationTitle, .focused etc. modifiers from the
      // call site still apply to this ProgressView since they're chained
      // on the function's return value.
      ProgressView()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Selection

  /// Snapshot of every category's folder assignment. Watched by `.onChange` so
  /// moving a category between folders (via DataWriter.moveCategoryToFolder)
  /// refreshes the article list.
  /// Extracted from body to keep the type-checker happy.
  private var categoryFolderLabels: [String?] {
    allCategories.map(\.folderLabel)
  }

  /// Re-key for the unread snapshot refresh task. Bumps on:
  /// - `entryRefreshVersion` — every mutation path that can change unread
  ///   membership (sync edge, classification drain, mark-read flush,
  ///   mark-all-read, category/folder reorganisation).
  /// - `folders.count`, `allCategories.count` — taxonomy edits that change
  ///   the dictionaries' keyspace without flipping any entry.
  /// - `syncEngine.queryCutoffDate` — Settings changes to `articleKeepDays`
  ///   move the cutoff and must invalidate the cached snapshot so the sidebar
  ///   badge counts re-align with `fetchEntrySections`. Cast to `Int`
  ///   (whole seconds since reference date) truncates sub-second jitter so
  ///   the key only changes on a real cutoff move (e.g. when
  ///   `refreshArticleCutoff()` runs after a Settings change), not on every
  ///   `Date()` re-evaluation.
  /// `entryRefreshVersion` uses `&+=` and wraps; string interpolation
  /// compares for equality, which handles the wrap.
  private var unreadSnapshotKey: String {
    let cutoffSeconds = Int(syncEngine.queryCutoffDate.timeIntervalSinceReferenceDate)
    return "\(entryRefreshVersion)|\(folders.count)|\(allCategories.count)|\(cutoffSeconds)"
  }

  /// Re-key for the classification drain task. A change in either component
  /// restarts the task: selection move ⇒ fresh dwell window; pending flag flip
  /// ⇒ pick up the newly-owed bump.
  private var classificationBumpDrainKey: String {
    "\(selectedEntry?.feedbinEntryID ?? -1)|\(pendingClassificationBump)"
  }

  /// Sibling of `classificationBumpDrainKey` for the sync-page drain. Re-keys
  /// on the same inputs so a selection move resets the dwell window and the
  /// pending flag transition both starts and clears the dwell task.
  private var syncBumpDrainKey: String {
    "sync|\(selectedEntry?.feedbinEntryID ?? -1)|\(pendingSyncBump)"
  }

  /// Tab from sidebar into the article-list column. Selecting the first row
  /// is gated on `currentEntries.ids` being non-empty, which is only true
  /// once the article list has rendered for the active `selection`. No
  /// selection or no rendered list ⇒ Tab moves focus only. Selection is
  /// ID-typed (issue #148) — the one live-model materialization happens in
  /// the `.onChange(of: selectedEntryID)` single writer.
  private func tabIntoArticleList() {
    panelFocus = .articleList
    guard let firstID = currentEntries.ids.first else { return }
    selectedEntryID = firstID
  }

  private func revalidateSelection() {
    switch selection {
    case .folder(let label) where !folders.contains(where: { $0.label == label }):
      selection = nil
    case .category(let label) where !allCategories.contains(where: { $0.label == label }):
      selection = nil
    default:
      break
    }
    if selection == nil {
      selection = sidebarItems.first { $0.isCategory }
    }
  }

  // MARK: - Actions

  /// Single point that invalidates the EntryListView's data refresh.
  /// Use whenever a mutation path can change what's shown in the timeline
  /// — sync edge, classification drain, mark-read flush, mark-all-read,
  /// category/folder reorganisation. Avoids drifting `&+=` bumps in five
  /// places.
  private func bumpEntryList() {
    entryRefreshVersion &+= 1
  }

  private func flushPendingReads() {
    let ids = pendingReadIDs
    guard !ids.isEmpty else { return }
    syncEngine.queueReadIDs(ids)
    Task {
      guard let writer = syncEngine.writer else { return }
      try? await writer.markEntriesRead(feedbinEntryIDs: ids)
      // Locally mutating isRead invalidates the article-list snapshot — refetch
      // so unread filter shrinks. Without this, scrubbed-past entries linger
      // (only dimmed via pendingReadIDs) until the next sync/classification.
      // The matching pendingReadIDs are pruned by `prunePendingReadIDs()` once
      // the MainActor `@Query` observes the background save — see the
      // `PendingReadPruneTrigger` modifier on `body`. Draining eagerly here
      // would race the auto-merge and could briefly bump the sidebar counts
      // back up.
      bumpEntryList()
    }
  }

  /// Prune the optimistic-read overlay with the TWO-SIDED retention criterion
  /// (issue #148, `retainedPendingReadIDs`): an ID is released only once BOTH
  /// the unread snapshot AND the currently-rendered rows confirm the
  /// committed `isRead == true` — so a snapshot refresh landing before the
  /// row DTOs refetch can never un-dim a row for a frame. Called from the
  /// snapshot-change trigger (`PendingReadPruneTrigger`) and from the
  /// `VisibleEntriesKey` preference change.
  private func prunePendingReadIDs() {
    guard !pendingReadIDs.isEmpty else { return }
    pendingReadIDs = retainedPendingReadIDs(
      pending: pendingReadIDs,
      snapshotUnread: unreadSnapshot.unreadFeedbinEntryIDs,
      renderedUnread: currentEntries.unreadFeedbinEntryIDs
    )
  }

  private func markAllAsRead() {
    // Sidebar `selection` is both what the user sees and the source of truth
    // for the article-list column — no separate "rendered" mirror to consult.
    guard articleFilter == .unread, let target = selection,
      let writer = syncEngine.writer
    else { return }
    selectedEntryID = nil
    let markTarget: MarkReadTarget
    let optimisticIDs: Set<Int>
    // Read the optimistic set out of the cached snapshot so the sidebar can
    // drop to zero in the same frame the article list empties — without
    // waiting for the background writer to commit and the snapshot refresh
    // task to land. The pre-computed `unreadIDByFolder` / `unreadIDByCategory`
    // dictionaries already group by the same axis the user selected.
    switch target {
    case .folder(let label):
      markTarget = .folder(label)
      optimisticIDs = unreadSnapshot.unreadIDByFolder[label] ?? []
    case .category(let label):
      markTarget = .category(label)
      optimisticIDs = unreadSnapshot.unreadIDByCategory[label] ?? []
    }
    pendingReadIDs.formUnion(optimisticIDs)
    Task {
      let markedIDs = try? await writer.markAllAsRead(
        target: markTarget, cutoffDate: syncEngine.queryCutoffDate
      )
      // Same rationale as flushPendingReads — refetch so the now-empty unread
      // list (or remaining unread items) appears immediately. The matching
      // pendingReadIDs are pruned by `prunePendingReadIDs()` once the
      // MainActor `@Query` observes the background save.
      bumpEntryList()
      guard let ids = markedIDs, !ids.isEmpty else { return }
      syncEngine.queueReadIDs(ids)
    }
  }

  private func openInBackground() {
    guard let entry = selectedEntry,
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

  // MARK: - Sidebar

  /// Snapshot of folder groups in DTO form. Built once per `body` evaluation
  /// and passed into the `Equatable` `SidebarView`, so SwiftUI can compare
  /// structural snapshots without crossing the SwiftData actor boundary.
  /// Only folders with at least one assigned category are surfaced — empty
  /// folders carry no sidebar weight.
  private var sidebarFolderGroupSnapshots: [SidebarFolderGroup] {
    visibleFolderGroups.map { group in
      SidebarFolderGroup(
        label: group.folder.label,
        displayName: group.folder.displayName,
        categories: group.categories.map { category in
          SidebarCategorySnapshot(label: category.label, displayName: category.displayName)
        }
      )
    }
  }

  /// Snapshot of root-level categories in DTO form. Same rationale as
  /// `sidebarFolderGroupSnapshots` — keeps the `Equatable` comparison
  /// structural.
  private var sidebarRootCategorySnapshots: [SidebarCategorySnapshot] {
    rootCategories.map { category in
      SidebarCategorySnapshot(label: category.label, displayName: category.displayName)
    }
  }

  @ViewBuilder
  private var sidebarView: some View {
    // Sidebar badge counts derive from the cached `unreadSnapshot`, which is
    // refreshed off-MainActor by `DataReader.fetchUnreadCountsSnapshot()` —
    // body never re-aggregates per evaluation. `pendingReadIDs` is the
    // optimistic-read overlay that already drives the dimmed state in
    // `EntryRowView`; subtracting it here keeps the badges in step with the
    // article list in the same frame, without flipping `isRead` eagerly.
    //
    // The overlay subtraction is bounded by the number of unique categories
    // (or folders) times the size of `pendingReadIDs` — both small. The
    // intersection against `unreadIDByCategory` / `unreadIDByFolder`
    // naturally excludes pending IDs that are no longer unread on disk, so
    // a stale cross-device flip cannot double-subtract.
    let pendingByCategory = pendingReadCountsByCategory(
      snapshot: unreadSnapshot, pending: pendingReadIDs)
    let pendingByFolder = pendingReadCountsByFolder(
      snapshot: unreadSnapshot, pending: pendingReadIDs)
    let categoryUnreadCounts = unreadSnapshot.categoryCounts
      .subtractingPendingCounts(pendingByCategory)
    let folderUnreadCounts = unreadSnapshot.folderCounts
      .subtractingPendingCounts(pendingByFolder)
    // EquatableView short-circuits the sidebar body whenever the structural
    // inputs above match the previous render — mark-read overlay flips,
    // selectedEntry changes, and detail-pane state never cross into the
    // sidebar's render path. Toolbar + key handlers stay outside so they
    // remain reactive to `syncEngine.isSyncing` / class-engine state.
    //
    // An earlier iteration dropped this wrap, suspecting it of hiding the
    // sidebar from XCUITest. `make test-full` on `main` (without this PR)
    // showed the same two UI tests already failing — so EquatableView is
    // exonerated and re-introduced. Pre-existing UI-test failures are
    // tracked separately as a follow-up issue.
    EquatableView(
      content: SidebarView(
        visibleFolderGroups: sidebarFolderGroupSnapshots,
        rootCategories: sidebarRootCategorySnapshots,
        categoryUnreadCounts: categoryUnreadCounts,
        folderUnreadCounts: folderUnreadCounts,
        fontBody: fontSettings.body,
        selection: $selection,
        collapsedFolders: $collapsedFolders
      )
    )
    .modifier(BareKeyHandler())
    .modifier(MarkAllReadKeyHandler(action: markAllAsRead))
    .accessibilityIdentifier("sidebar.list")
    .toolbar {
      ToolbarItem {
        Button {
          Task { await syncAndClassify() }
        } label: {
          if syncEngine.isSyncing || classificationEngine.isClassifying {
            ProgressView()
              .scaleEffect(0.7)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .disabled(syncEngine.isSyncing || classificationEngine.isClassifying)
        .help("Sync and classify")
        .accessibilityIdentifier("toolbar.sync")
      }
    }
  }

  /// The navigation title tracks the sidebar `selection` directly. There is no
  /// debounced mirror to consult — selection commits and the content column
  /// re-renders in the same frame.
  private var navigationTitle: String {
    switch selection {
    case .folder(let label):
      return folders.first { $0.label == label }?.displayName ?? "Articles"
    case .category(let label):
      return allCategories.first { $0.label == label }?.displayName ?? "Articles"
    case nil:
      return "Articles"
    }
  }

  // MARK: - Detail

  @ViewBuilder
  private var detailView: some View {
    Group {
      if let selectedEntry {
        EntryDetailView(entry: selectedEntry, viewMode: articleViewMode)
      } else {
        ContentUnavailableView {
          Label("Select an Article", systemImage: "doc.text")
        } description: {
          Text("Choose an article from the list to read it.")
        }
      }
    }
    .modifier(BareKeyHandler())
    .modifier(MarkAllReadKeyHandler(action: markAllAsRead))
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          toggleArticleViewMode()
        } label: {
          Label(
            articleViewMode == .web ? "Reader Mode" : "Web Mode",
            systemImage: articleViewMode == .web ? "doc.plaintext" : "doc.richtext"
          )
        }
        .help(articleViewMode == .web ? "Switch to reader mode (R)" : "Switch to web mode (R)")
        .disabled(selectedEntry == nil)
      }
      ToolbarItem(placement: .automatic) {
        Button {
          openInBackground()
        } label: {
          Label("Open in Browser", systemImage: "safari")
        }
        .help("Open in browser (B)")
        .disabled(selectedEntry == nil)
      }
    }
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
      if selection == nil {
        if let firstFolder = folders.first {
          selection = .folder(firstFolder.label)
        }
      }
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
  /// Feedbin client so no sync can reach the network, seeds the perf fixture so
  /// the three panes render a real reading state, and selects the first folder.
  ///
  /// Crucially this returns from `checkCredentials` BEFORE any
  /// `KeychainHelper.load`, `needsSetup`, or `startSync` — so an automated
  /// launch never triggers a macOS Keychain consent prompt, shows onboarding, or
  /// contacts Feedbin. The store is already in-memory (`FeederApp.init` gated on
  /// the same `HeadlessMode.isEnabled`), so this reading state never touches the
  /// user's real on-disk data.
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
      if selection == nil {
        selection = .folder("technology")
      }
    }
  }

  /// Drive the headless perf scenario. Attaches a `DataWriter` so
  /// `EntryListView` can render the seeded rows, then hands control to
  /// `PerfScenarioRunner` which mutates `selection`, `selectedEntryID`, and
  /// `articleViewMode` on MainActor — the same writes the user would make.
  /// `exit(0)` inside the runner ends the launch so `xctrace` finalises the
  /// recorded trace.
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
          selection = newSelection
          selectedEntryID = newEntryID
          articleViewMode = newMode
        },
        visibleEntryIDs: {
          // The runner picks the first visible row to click; selection is
          // ID-typed (issue #148) so no Entry materialization is needed here
          // — the `.onChange(of: selectedEntryID)` single writer resolves it.
          currentEntries.ids
        },
        navigate: { direction in
          // Route through the real J/K handler so the walk pays the actual
          // per-keystroke `sidebarItems → visibleFolderGroups → inFolder`
          // recompute + `panelFocus` resolution — not a bare `selection =`.
          switch direction {
          case .next: _ = bareKeyActions.onJ()
          case .previous: _ = bareKeyActions.onK()
          }
        },
        bumpEntryList: { bumpEntryList() },
        currentSelection: { selection }
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
      let seeded = try? await writer.seedUITestData()
      if seeded == true {
        selection = .folder("technology")
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
  private func startSync(username preloadedUsername: String? = nil, password preloadedPassword: String? = nil) {
    let username = preloadedUsername ?? UserDefaults.standard.string(forKey: feedbinUsernameUserDefaultsKey) ?? ""
    let password = preloadedPassword ?? KeychainHelper.load(key: KeychainHelper.feedbinPasswordKey) ?? ""
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

      let syncInterval = UserDefaults.standard.double(forKey: syncIntervalUserDefaultsKey).clamped(to: 60...3600, default: 300)
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
    label: "apple", displayName: "Apple", categoryDescription: "Apple preview", sortOrder: 0, folderLabel: "technology")
  let world = Category(label: "world_news", displayName: "World News", categoryDescription: "World coverage for preview", sortOrder: 0)
  context.insert(apple)
  context.insert(world)

  let feed1 = Feed(
    feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "The Verge", feedURL: "https://theverge.com/rss",
    siteURL: "https://theverge.com", createdAt: .now)
  context.insert(feed1)

  for i in 1...5 {
    let entry = Entry(
      feedbinEntryID: i, title: "Sample Tech Story \(i)", author: "Feeder Bot", url: "https://example.com/\(i)",
      content: "<p>Sample article \(i).</p>", summary: "Sample \(i)", extractedContentURL: nil,
      publishedAt: .now.addingTimeInterval(-Double(i) * 900), createdAt: .now.addingTimeInterval(-Double(i) * 850))
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
