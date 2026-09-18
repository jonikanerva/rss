import Foundation
import SwiftData
import SwiftUI
import os.signpost

// MARK: - Content View

struct ContentView: View {
  /// Hold time before a finished classification batch may refresh the article
  /// list. The refresh rebuilds the `List` and can reseat the scroll anchor
  /// around the selected row, so it waits until the selection has been stable
  /// for this long.
  fileprivate static let classificationBumpDwell: Duration = .seconds(4)
  /// Coalescing window for classification bumps when no row is selected. Each
  /// progress tick would otherwise trigger a full re-fetch.
  fileprivate static let classificationIdleThrottle: Duration = .seconds(1)
  /// Coalescing window for sync-page bumps, with and without a selection. New
  /// rows land at the top and `List` keeps the scroll anchor, so this dwell
  /// only collapses a burst of pages into one re-fetch.
  fileprivate static let syncBumpDwell: Duration = .milliseconds(750)
  /// Entry count seeded for the headless reading state. Large enough to fill
  /// the perf seeder's categories, small enough to keep the automated launch
  /// fast.
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
  @Query(filter: #Predicate<Category> { $0.folderLabel == nil }, sort: \Category.sortOrder)
  private var rootCategories: [Category]
  /// Cached aggregation over the classified-unread universe. Refreshed only by
  /// `UnreadSnapshotRefreshTask`; never re-aggregate it inside `body`.
  @State
  private var unreadSnapshot: UnreadCountsSnapshot = .empty
  /// Launch `ideal` of the content column: read once from `ColumnWidthSetting`
  /// when this view's identity is created, never written. `@State` pins the
  /// value so a re-construction after a persisted drag cannot hand the split
  /// view a new `ideal` mid-session. Must not become a live binding — a
  /// changing `ideal` makes the divider fight the user's drag. `ideal` only:
  /// no `min`, no `max`.
  @State
  private var contentColumnIdealWidth: CGFloat = ColumnWidthSetting.restoredIdealWidth(for: .content)
  /// Launch `ideal` of the sidebar. Same rules as `contentColumnIdealWidth`.
  @State
  private var sidebarIdealWidth: CGFloat = ColumnWidthSetting.restoredIdealWidth(for: .sidebar)
  @AppStorage("sidebar.collapsedFolders")
  private var collapsedFolders: SidebarCollapsedFolders = .init()
  /// Source of truth for the article-list selection: the row DTO's
  /// `PersistentIdentifier`.
  @State
  private var selectedEntryID: PersistentIdentifier?
  /// Memoized live model for the selected row — the one full `Entry`
  /// materialization per selection. Write it in exactly one place, the
  /// `.onChange(of: selectedEntryID)` handler; every other consumer only
  /// reads it.
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
  /// Rendered-entries payload bubbled up from `EntryListView`: the visible ids
  /// plus the rendered-unread ids, which are one side of the two-sided
  /// `pendingReadIDs` retention prune.
  @State
  private var currentEntries: VisibleEntriesPayload = .empty
  /// App-lifetime favicon cache: decoded once per feed, off the render path.
  @State
  private var faviconStore = FaviconStore()
  /// Bumped whenever underlying article data may have changed. `EntryListView`
  /// includes it in its `.task(id:)` key. Mutate it only through
  /// `bumpEntryList()`.
  @State
  private var entryRefreshVersion: Int = 0
  /// Snapshot-only refresh channel: bump it when a write changed unread
  /// membership but the visible window provably cannot change. It feeds
  /// `unreadSnapshotKey` alone, so the sidebar snapshot refetches without a
  /// whole-window refetch of the article list.
  @State
  private var snapshotRefreshVersion: Int = 0
  /// Set when a scene-inactive flush queues a write with its list bump
  /// suppressed. Exactly one `bumpEntryList()` on the next `.active`
  /// transition consumes it, so a suppressed update is delayed, never dropped.
  @State
  private var owedListBumpOnResume = false
  /// Set when a classification batch finishes and a refresh is owed. Drained by
  /// `DeferredBumpDrainTrigger` once the selection has been stable, so a
  /// background refresh never yanks the list under the user.
  @State
  private var pendingClassificationBump = false
  /// Sync-page sibling of `pendingClassificationBump`, drained on a shorter
  /// dwell so persisted entries appear as pages arrive.
  @State
  private var pendingSyncBump = false
  @FocusState
  private var panelFocus: PanelFocus?
  /// In-flight click → render signpost states. `@State` keeps the begin alive
  /// across the SwiftUI commit boundary to the matching end.
  @State
  private var sidebarClickIntervalState: OSSignpostIntervalState?
  @State
  private var articleClickIntervalState: OSSignpostIntervalState?
  /// Diagnostic interval for the whole-split-view re-eval: begins when a
  /// `VisibleEntriesKey` payload arrives, ends on the next render pass via
  /// `.task(id: contentReevalVersion)`.
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
        // `sidebarView` has one stable identity, so the recorder sits on it
        // directly with no wrapper. A hidden sidebar measures 0 and the
        // recorder's sanity floor skips it.
        .persistedColumnWidth(column: .sidebar, ideal: sidebarIdealWidth)
    } content: {
      // The width recorder and preference must sit on a `ZStack`, not a
      // `Group`: `Group` re-applies its modifiers per branch, so the launch
      // branch swap would reset the recorder's identity and restart its
      // launch-layout skip. Both branches fill the `ZStack`, so the measured
      // width is the column's, not the window's.
      ZStack {
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
      }
      .persistedColumnWidth(column: .content, ideal: contentColumnIdealWidth)
    } detail: {
      detailView
    }
    .environment(\.bareKeyActions, bareKeyActions)
    .environment(faviconStore)
    .onPreferenceChange(VisibleEntriesKey.self) { payload in
      // Open the interval before the writes below dirty `ContentView`; the
      // paired end fires on the next render pass.
      contentReevalIntervalState = perfSignposter.beginInterval(
        PerformanceSignpostName.contentViewReeval
      )
      contentReevalVersion &+= 1
      currentEntries = payload
      // Second prune trigger: the rendered-unread side of the retention
      // criterion just changed, so release confirmed IDs here too and not
      // only on the next snapshot refresh.
      prunePendingReadIDs()
    }
    .task(id: contentReevalVersion) {
      guard let state = contentReevalIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.contentViewReeval, state)
      contentReevalIntervalState = nil
    }
    .onAppear {
      // The root view appears once per launch, so each column's launch width
      // is logged exactly once.
      ColumnWidthDiagnostics.logRestoredIdeal(sidebarIdealWidth, for: .sidebar)
      ColumnWidthDiagnostics.logRestoredIdeal(contentColumnIdealWidth, for: .content)
      checkCredentials()
      revalidateSelection()
      panelFocus = .sidebar
    }
    // `.task` runs once after the root view appears, so the warm lands before
    // the user can click an article but after the first render is committed.
    // `.utility` keeps it below user-initiated work. The warm itself is a
    // synchronous MainActor call, because `WKWebView` is MainActor-only, and
    // it is idempotent, so a re-attached view is a no-op.
    .task(priority: .utility) {
      // WKWebView's GPU and Web processes are unstable in the sandboxed
      // headless host and crash long unattended runs. `WebKitPreheatTests`
      // call `warmIfNeeded()` directly, so this gate keeps their coverage.
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
      // The single writer for `selectedEntry`: resolve the one live model per
      // selection commit here, at the interface↔store boundary. Every other
      // consumer reads the memoized `@State`.
      let newEntry = newID.flatMap { modelContext.model(for: $0) as? Entry }
      selectedEntry = newEntry
      // Defer the pending-read insertion off the selection-commit critical
      // path: an in-frame mutation cascades through the sidebar counts and
      // the row dimming overlay, nudging row metrics on the same frame as the
      // keystroke. Mark-read reads the live `entry.isRead`, which is fresher
      // than the row DTO's snapshot.
      if let entry = newEntry, !entry.isRead {
        applyPendingReadAfterYield(feedbinEntryID: entry.feedbinEntryID) { id in
          pendingReadIDs.insert(id)
        }
      }
      articleViewMode = .web
      // No begin when the selection clears: the empty state has no render
      // cost to measure.
      if newEntry != nil {
        articleClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.articleClick
        )
      }
    }
    .task(id: selectedEntry?.feedbinEntryID) {
      // Pairs with the begin in `.onChange(of: selectedEntryID)`. No sleep
      // here: the interval must stay bounded to "selection commit ⇒ next
      // render pass".
      guard let state = articleClickIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.articleClick, state)
      articleClickIntervalState = nil
    }
    .onChange(of: articleFilter) {
      // The filter flip is the one flush caller that needs a post-commit list
      // bump: the flipped rows change membership in the new filter's window,
      // and the structural refetch can run before the flush commits. Ordering
      // is pinned by `WindowRefreshGateTests`.
      flushPendingReads(thenBumpListAfterCommit: true)
      selectedEntryID = nil
    }
    .onChange(of: selection) { _, newSelection in
      // No list bump: the sidebar move re-keys the structural task, whose
      // first page covers the new axis, and the flush's snapshot bump handles
      // the sidebar counts and the overlay release.
      flushPendingReads()
      selectedEntryID = nil
      if newSelection != nil {
        sidebarClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.sidebarClick
        )
      }
    }
    .task(id: selection) {
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
      if scenePhase == .active {
        // Consume the owed bump: the inactive-phase flush suppressed its
        // refetch, so one bump on resume shows the committed state. This runs
        // before a new suppression can be owed, so the bit never double-fires.
        if owedListBumpOnResume {
          owedListBumpOnResume = false
          bumpEntryList()
        }
      } else {
        // Background work pauses while the surface is not visible, so the
        // list bump is suppressed and the owed bit bounds that suppression to
        // the next `.active` transition. The bit is set at queue time, so a
        // resume racing the commit costs one early refresh, never a dropped
        // update; the overlay keeps the rows dimmed meanwhile.
        if flushPendingReads() {
          owedListBumpOnResume = true
        }
        Task { await syncEngine.pushPendingReads() }
      }
    }
    // The modifier owns the `.task(id:)` so `body` stays inside SwiftUI's
    // type-checker budget.
    .modifier(
      UnreadSnapshotRefreshTask(
        key: unreadSnapshotKey,
        reader: syncEngine.reader,
        cutoffDate: syncEngine.queryCutoffDate,
        snapshot: $unreadSnapshot
      )
    )
    // Drop an ID from the optimistic overlay once a background write flips it
    // out of the snapshot, so the set cannot grow unbounded across a long
    // session or mask a later cross-device unread flip on the same ID.
    .modifier(
      PendingReadPruneTrigger(
        unreadCount: unreadSnapshot.totalUnread,
        onUnreadCountChange: { prunePendingReadIDs() }
      )
    )
    // Both edges fire when the work finishes, and only when that batch
    // actually changed rows. A quiet tick must leave the list untouched.
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
    // `MidFlightBumpRouter` is a leaf `View`, not a `ViewModifier`, so the
    // mid-flight version reads live in its own body. Reading them in
    // `ContentView.body` would invalidate the whole split view on every sync
    // page and every classification progress tick.
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
    // Escape and Tab stay at `NavigationSplitView` level so `List`
    // type-to-select cannot consume them.
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
    // J/K/R/B route three ways. The per-panel `BareKeyHandler` modifiers fire
    // while a `List` has focus and keep bare keys out of text fields, where
    // typing must type. `BareKeyForwardingWebView` forwards the same actions
    // from inside the article web view, where the AppKit first responder
    // swallows key events. This root fallback covers every state in which no
    // focusable surface holds focus.
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

  /// Folders that hold at least one category, paired with their categories.
  /// Re-evaluated on every J/K keystroke, so keep the work proportional to the
  /// folder count.
  private var visibleFolderGroups: [(folder: Folder, categories: [Category])] {
    folders.compactMap { folder in
      let categoriesInFolder = allCategories.inFolder(folder.label)
      guard !categoriesInFolder.isEmpty else { return nil }
      return (folder, categoriesInFolder)
    }
  }

  /// Flat ordered sidebar items in keyboard-visible order. A folder with no
  /// categories, and the child rows of a collapsed folder, contribute nothing:
  /// otherwise J/K lands on a row the user cannot see.
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

  // MARK: - Focus-following selection bindings

  // FOCUS-FOLLOWS-CLICK invariant: only `List`'s user-interaction writes — a
  // click or an in-list arrow move — may route through these setters. Every
  // programmatic write assigns the underlying `@State` directly and must keep
  // doing so; routing one through a setter steals keyboard focus mid-read.

  /// Selection binding for the sidebar `List`: commits the selection, then
  /// moves focus to the sidebar so arrow keys work right after a click. A
  /// `nil` write never moves focus.
  private var sidebarSelectionBinding: Binding<SidebarSelection?> {
    Binding(
      get: { selection },
      set: { newValue in
        selection = newValue
        if newValue != nil { panelFocus = .sidebar }
      }
    )
  }

  /// Article-list sibling of `sidebarSelectionBinding`, targeting
  /// `.articleList`.
  private var entrySelectionBinding: Binding<PersistentIdentifier?> {
    Binding(
      get: { selectedEntryID },
      set: { newValue in
        selectedEntryID = newValue
        if newValue != nil { panelFocus = .articleList }
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
        selectedEntryID: entrySelectionBinding, onMarkAllRead: markAllAsRead
      )
    } else {
      // First launch, before `SyncEngine.configure` completes. The call
      // site's modifiers still apply to this branch.
      ProgressView()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Selection

  /// Snapshot of every category's folder assignment. Watched so that moving a
  /// category between folders refreshes the article list.
  private var categoryFolderLabels: [String?] {
    allCategories.map(\.folderLabel)
  }

  /// Re-key for the unread snapshot refresh task. `cutoffSeconds` truncates to
  /// whole seconds so the key moves only on a real cutoff change, not on every
  /// `Date()` re-evaluation. The version components wrap with `&+=`, and the
  /// key is compared for equality, which handles the wrap. Composition is
  /// pinned by `WindowRefreshGateTests`.
  private var unreadSnapshotKey: String {
    Self.composeUnreadSnapshotKey(
      entryRefreshVersion: entryRefreshVersion,
      snapshotRefreshVersion: snapshotRefreshVersion,
      folderCount: folders.count,
      categoryCount: allCategories.count,
      cutoffSeconds: Int(syncEngine.queryCutoffDate.timeIntervalSinceReferenceDate)
    )
  }

  /// Pure key builder behind `unreadSnapshotKey`, extracted so tests can pin
  /// its composition.
  nonisolated static func composeUnreadSnapshotKey(
    entryRefreshVersion: Int, snapshotRefreshVersion: Int,
    folderCount: Int, categoryCount: Int, cutoffSeconds: Int
  ) -> String {
    "\(entryRefreshVersion)|\(snapshotRefreshVersion)|\(folderCount)|\(categoryCount)|\(cutoffSeconds)"
  }

  /// Re-key for the classification drain task: a selection move starts a fresh
  /// dwell window, a pending-flag flip picks up the newly-owed bump.
  private var classificationBumpDrainKey: String {
    "\(selectedEntry?.feedbinEntryID ?? -1)|\(pendingClassificationBump)"
  }

  /// Sync-page sibling of `classificationBumpDrainKey`, re-keyed on the same
  /// inputs.
  private var syncBumpDrainKey: String {
    "sync|\(selectedEntry?.feedbinEntryID ?? -1)|\(pendingSyncBump)"
  }

  /// Tab from the sidebar into the article-list column. Selecting the first
  /// row is gated on `currentEntries.ids`, which fills only once the list has
  /// rendered for the active `selection`; without rendered rows Tab moves
  /// focus alone.
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

  /// Single point that invalidates `EntryListView`'s data refresh. Call it
  /// after any mutation that can change what the timeline shows.
  ///
  /// POST-COMMIT CONTRACT: call only after the mutating write's `await` has
  /// returned. `EntryListView` treats a bump at or below its pre-fetch
  /// snapshot as already fetched, so a bump fired before its write commits is
  /// silently dropped.
  private func bumpEntryList() {
    entryRefreshVersion &+= 1
  }

  /// Snapshot-channel sibling of `bumpEntryList`: refetches the sidebar unread
  /// snapshot without refetching the visible window. Use it when a committed
  /// write changed unread membership but the rendered rows cannot change. Same
  /// post-commit contract as `bumpEntryList`.
  private func bumpUnreadSnapshot() {
    snapshotRefreshVersion &+= 1
  }

  /// Queue the optimistic-read overlay for a committed `markEntriesRead`
  /// write. Returns `true` when a flush was queued, so the scene-inactive
  /// caller can record its owed resume bump. A caller that also needs the
  /// visible window refetched must ask for it explicitly.
  @discardableResult
  private func flushPendingReads(thenBumpListAfterCommit: Bool = false) -> Bool {
    let ids = pendingReadIDs
    guard !ids.isEmpty else { return false }
    syncEngine.queueReadIDs(ids)
    Task {
      guard let writer = syncEngine.writer else { return }
      try? await writer.markEntriesRead(feedbinEntryIDs: ids)
      // Post-commit, and the snapshot channel only: the rendered rows already
      // show the flipped state. This refetch is still mandatory, because
      // `prunePendingReadIDs` releases retained IDs only once the snapshot
      // confirms the committed flips.
      bumpUnreadSnapshot()
      if thenBumpListAfterCommit {
        bumpEntryList()
      }
    }
    return true
  }

  /// Prune the optimistic-read overlay: release an ID only once both the
  /// unread snapshot and the rendered rows confirm `isRead == true`, so a
  /// snapshot refresh landing before the row DTOs refetch cannot un-dim a row.
  ///
  /// `renderedUnread` covers the loaded window only. An ID beyond that window
  /// has no rendered row to un-dim, so the unbounded snapshot side alone
  /// governs its release.
  private func prunePendingReadIDs() {
    guard !pendingReadIDs.isEmpty else { return }
    pendingReadIDs = retainedPendingReadIDs(
      pending: pendingReadIDs,
      snapshotUnread: unreadSnapshot.unreadFeedbinEntryIDs,
      renderedUnread: currentEntries.unreadFeedbinEntryIDs
    )
  }

  private func markAllAsRead() {
    guard articleFilter == .unread, let target = selection,
      let writer = syncEngine.writer
    else { return }
    selectedEntryID = nil
    let markTarget: MarkReadTarget
    let optimisticIDs: Set<Int>
    // Read the optimistic set from the cached snapshot so the sidebar drops to
    // zero in the same frame the article list empties, without waiting for the
    // background writer to commit.
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
      // Post-commit. Unlike the flush, mark-all-read changes the visible
      // window itself, so the list must refetch immediately.
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

  /// Folder groups in DTO form, so the `Equatable` `SidebarView` compares
  /// structural snapshots without crossing the SwiftData actor boundary. Only
  /// folders with at least one category are surfaced.
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

  /// Root categories in DTO form, for the same `Equatable` comparison as
  /// `sidebarFolderGroupSnapshots`.
  private var sidebarRootCategorySnapshots: [SidebarCategorySnapshot] {
    rootCategories.map { category in
      SidebarCategorySnapshot(label: category.label, displayName: category.displayName)
    }
  }

  @ViewBuilder
  private var sidebarView: some View {
    // Badge counts derive from the cached `unreadSnapshot`; `body` never
    // re-aggregates. Subtracting the overlay here keeps the badges in step
    // with the article list in the same frame, without flipping `isRead`
    // eagerly. The intersection against the snapshot's per-axis id sets drops
    // IDs that are no longer unread on disk, so a stale cross-device flip
    // cannot double-subtract.
    let pendingByCategory = pendingReadCountsByCategory(
      snapshot: unreadSnapshot, pending: pendingReadIDs)
    let pendingByFolder = pendingReadCountsByFolder(
      snapshot: unreadSnapshot, pending: pendingReadIDs)
    let categoryUnreadCounts = unreadSnapshot.categoryCounts
      .subtractingPendingCounts(pendingByCategory)
    let folderUnreadCounts = unreadSnapshot.folderCounts
      .subtractingPendingCounts(pendingByFolder)
    // `EquatableView` short-circuits the sidebar body whenever the structural
    // inputs match the previous render, so overlay flips and detail-pane state
    // never reach the sidebar's render path. Toolbar and key handlers stay
    // outside the wrap so they keep observing the engines.
    EquatableView(
      content: SidebarView(
        visibleFolderGroups: sidebarFolderGroupSnapshots,
        rootCategories: sidebarRootCategorySnapshots,
        categoryUnreadCounts: categoryUnreadCounts,
        folderUnreadCounts: folderUnreadCounts,
        fontBody: fontSettings.body,
        selection: sidebarSelectionBinding,
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
      // Preview canvases seed their container directly and never run
      // `configure`, so attach a writer here or `EntryListView` spins on
      // `ProgressView` forever.
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
      // Pass the loaded password through so `startSync` does not trigger a
      // second keychain consent prompt for the same item.
      startSync(username: username, password: password)
    }
  }

  /// Boot the self-contained headless reading state. Returns from
  /// `checkCredentials` before any `KeychainHelper.load`, `needsSetup`, or
  /// `startSync`, so an automated launch never prompts for Keychain access,
  /// shows onboarding, or contacts Feedbin. The store is already in-memory, so
  /// this state never touches the user's on-disk data.
  private func bootHeadless() {
    let container = modelContext.container
    // Defence in depth: an inert client means no sync path can reach Feedbin.
    syncEngine.attachClient(InertFeedbinClient())
    Task {
      let writer = await DataWriter.makeDetached(modelContainer: container)
      let reader = await DataReader.makeDetached(modelContainer: container)
      syncEngine.attachWriter(writer)
      syncEngine.attachReader(reader)
      // The perf seeder gives every entry exactly one category and strict
      // newest-first order, honouring the `VISION.md` invariants.
      _ = try? await writer.seedPerfTestData(entryCount: Self.headlessSeedEntryCount)
      if selection == nil {
        selection = .folder("technology")
      }
    }
  }

  /// Drive the headless perf scenario. `PerfScenarioRunner` mutates
  /// `selection`, `selectedEntryID`, and `articleViewMode` on MainActor — the
  /// same writes the user would make — and calls `exit(0)` so `xctrace`
  /// finalises the recorded trace.
  private func runPerfScenario() {
    let container = modelContext.container
    Task { @MainActor in
      let writer = await DataWriter.makeDetached(modelContainer: container)
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
        visibleEntryIDs: { currentEntries.ids },
        navigate: { direction in
          // Route through the real J/K handler so the walk pays the actual
          // per-keystroke recompute, not a bare `selection =`.
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
      // Without a writer the demo-mode launch sticks on `ProgressView`.
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

  /// Start (or resume) periodic Feedbin sync. `checkCredentials()` passes the
  /// already-loaded credentials through to avoid a second Keychain read, and
  /// therefore a second consent prompt, on the first launch after install. The
  /// onboarding call site keeps the no-argument form.
  private func startSync(username preloadedUsername: String? = nil, password preloadedPassword: String? = nil) {
    let username = preloadedUsername ?? UserDefaults.standard.string(forKey: feedbinUsernameUserDefaultsKey) ?? ""
    let password = preloadedPassword ?? KeychainHelper.load(key: KeychainHelper.feedbinPasswordKey) ?? ""
    guard !username.isEmpty, !password.isEmpty else { return }

    // `FeederApp.runBootstrap()` attaches the production writer before this
    // view renders, so only the credentials are configured here.
    syncEngine.configure(username: username, password: password)

    Task {
      // The reads already filter on `publishedAt >= cutoffDate`, so this purge
      // only stops the store growing without bound. Passing the ceiling
      // derived from `maxRetentionAge` keeps a change to `articleKeepDays`
      // from needing a refetch and recategorise round-trip.
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
