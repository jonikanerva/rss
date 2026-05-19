import Foundation
import SwiftData
import SwiftUI

// MARK: - Content View root
//
// `EntryListView`, `SyncStatusView`, and the sidebar/key-handling helpers
// live in dedicated files — see `Views/EntryListView.swift`,
// `Views/SyncStatusView.swift`, and `Views/Support/*`. ContentView stays
// focused on the NavigationSplitView layout, selection debouncing, sync
// bootstrap, and menu-bar action wiring.

// MARK: - Content View

struct ContentView: View {
  /// Dwell time before propagating a keyboard-driven selection change to a heavy
  /// downstream view (WebView render or article-list background fetch). Short
  /// enough that single intentional taps still feel instant; long enough to
  /// suppress per-keystroke work during arrow-key scrubbing.
  fileprivate static let renderDwell: Duration = .milliseconds(150)
  /// Hold time before a finished classification batch is allowed to refresh the
  /// article list while the user is actively browsing. Bumping
  /// `entryRefreshVersion` causes `EntryListView` to re-fetch sections; if any
  /// row gained or lost a category in that batch, the `List` rebuilds and may
  /// reseat its scroll anchor around the selected row — the user perceives
  /// this as the list "jumping" when they were just scrolling/clicking. We
  /// defer the bump until the user's selection has been stable for this long
  /// (or selection clears) so the refresh lands at a quiet moment.
  fileprivate static let classificationBumpDwell: Duration = .seconds(4)
  /// Shorter dwell for sync-page bumps. New entries persisted by a sync page
  /// land at the top of the list via stable-ID diffing — `List` preserves the
  /// scroll anchor around the selected row, so a near-immediate refresh stays
  /// non-disruptive. The dwell still buys a small coalescing window so a
  /// burst of pages collapses into one re-fetch instead of N.
  fileprivate static let syncBumpDwell: Duration = .milliseconds(750)

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
  /// Classified-unread entries — the universe over which sidebar badges are
  /// aggregated. Filtering happens at the SQLite level so the count of rows
  /// pulled into MainActor is bounded by unread inventory, not total entries.
  /// Aggregation into per-category and per-folder dictionaries is O(n) Swift
  /// (where n = unread count), computed once per `@Query` snapshot and read
  /// by `body` as dictionary lookups — no work during row rendering.
  @Query(filter: #Predicate<Entry> { $0.isClassified == true && $0.isRead == false })
  private var unreadEntries: [Entry]
  @AppStorage("sidebar.collapsedFolders")
  private var collapsedFolders: SidebarCollapsedFolders = .init()
  @State
  private var selectedEntry: Entry?
  /// Debounced mirror of `selectedEntry`. The detail pane (WebView) renders this,
  /// not `selectedEntry`, so rapid keyboard scrubbing doesn't trigger a WebKit
  /// load + HTML rebuild for every intermediate article. See `.task(id:)` modifier
  /// on `body` that drives this from `selectedEntry` after a short dwell time.
  @State
  private var renderedEntry: Entry?
  @State
  private var selection: SidebarSelection?
  /// Debounced mirror of `selection`. The article-list column reads this, not
  /// `selection`, so rapid sidebar arrow scrubbing doesn't kick off a fresh
  /// `DataWriter.fetchEntrySections` background fetch on every keystroke (each
  /// cancelled fetch still wastes a small amount of background work). Driven
  /// by `.task(id: selection)` after a short dwell time.
  @State
  private var renderedSelection: SidebarSelection?
  @State
  private var articleFilter: ArticleFilter = .unread
  @State
  private var articleViewMode: ArticleViewMode = .web
  @State
  private var needsSetup = false
  @State
  private var pendingReadIDs: Set<Int> = []
  @State
  private var currentEntryIDs: [PersistentIdentifier] = []
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
  private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
  private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
  private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    NavigationSplitView {
      sidebarView
        .focused($panelFocus, equals: .sidebar)
    } content: {
      if let renderedSelection {
        entryListForSelection(renderedSelection)
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
    .onPreferenceChange(VisibleEntryIDsKey.self) { currentEntryIDs = $0 }
    .onAppear {
      checkCredentials()
      revalidateSelection()
      panelFocus = .sidebar
    }
    .sheet(isPresented: $needsSetup) {
      OnboardingView {
        needsSetup = false
        startSync()
      }
      .environment(syncEngine)
    }
    .onChange(of: selectedEntry) { _, newEntry in
      if let entry = newEntry, !entry.isRead {
        pendingReadIDs.insert(entry.feedbinEntryID)
      }
      articleViewMode = .web
      // Clear the rendered entry immediately when selection clears so the
      // empty-state view appears without a delay.
      if newEntry == nil {
        renderedEntry = nil
      }
    }
    .task(id: selectedEntry?.feedbinEntryID) {
      // Debounce: WebView only loads HTML for entries the user dwells on long
      // enough to matter. When selectedEntry changes again before the sleep
      // completes, this task is cancelled and the in-flight load is skipped —
      // so holding Down arrow no longer triggers N WebKit reloads +
      // buildHTML cycles on MainActor.
      guard selectedEntry != nil else { return }
      try? await Task.sleep(for: Self.renderDwell)
      guard !Task.isCancelled else { return }
      renderedEntry = selectedEntry
    }
    .onChange(of: articleFilter) {
      flushPendingReads()
      selectedEntry = nil
    }
    .onChange(of: selection) { _, newSelection in
      flushPendingReads()
      selectedEntry = nil
      // Clear the rendered article-list column immediately when no sidebar
      // item is selected so the empty-state appears without delay.
      if newSelection == nil {
        renderedSelection = nil
      }
    }
    .task(id: selection) {
      // Debounce: only fire `EntryListView` (and its background
      // `DataWriter.fetchEntrySections` call) for sidebar selections the user
      // dwells on for >150 ms. The fetch is cancellable and non-blocking, but
      // each cancelled fetch still wastes a small amount of background work,
      // so debouncing keeps fast scrubbing efficient.
      guard selection != nil else { return }
      try? await Task.sleep(for: Self.renderDwell)
      guard !Task.isCancelled else { return }
      renderedSelection = selection
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
    // Keep `pendingReadIDs` aligned with the live SQLite-side unread snapshot:
    // when a background write (mark-read / mark-all-read / sync) flips
    // entries out of `unreadEntries`, drop their IDs from the optimistic
    // overlay so the set does not grow unbounded across a long session and
    // does not mask a future cross-device unread flip on the same ID.
    .modifier(
      PendingReadPruneTrigger(
        unreadCount: unreadEntries.count,
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
    .modifier(
      MidFlightBumpRouter(
        syncPageVersion: syncEngine.lastPersistedPageVersion,
        classificationBatchVersion: classificationEngine.batchProgressVersion,
        pendingSyncBump: $pendingSyncBump,
        pendingClassificationBump: $pendingClassificationBump
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: classificationBumpDrainKey,
        dwell: Self.classificationBumpDwell,
        hasSelection: selectedEntry != nil,
        pendingBump: $pendingClassificationBump,
        onDrain: { bumpEntryList() }
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: syncBumpDrainKey,
        dwell: Self.syncBumpDwell,
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
      selectedEntry = nil
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
        canMarkAllRead: articleFilter == .unread && renderedSelection != nil,
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
    if let writer = syncEngine.writer {
      let (category, folder): (String?, String?) =
        switch sel {
        case .category(let label): (label, nil)
        case .folder(let label): (nil, label)
        }
      EntryListView(
        category: category, folder: folder, filter: articleFilter,
        cutoffDate: syncEngine.queryCutoffDate, writer: writer,
        refreshVersion: entryRefreshVersion,
        pinnedFeedbinEntryID: selectedEntry?.feedbinEntryID,
        selectedEntry: $selectedEntry, onMarkAllRead: markAllAsRead
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

  /// Tab from sidebar into the article-list column. No-ops entirely during
  /// the `renderedSelection` debounce window — if focus moved to the outgoing
  /// list, subsequent arrow-key navigation or Shift+A would act on the
  /// previous category even though the sidebar already shows the new one.
  /// The user waits ~150 ms or presses Tab again once alignment settles.
  private func tabIntoArticleList() {
    guard selection == renderedSelection else { return }
    panelFocus = .articleList
    guard let firstID = currentEntryIDs.first else { return }
    guard let firstEntry = modelContext.model(for: firstID) as? Entry else { return }
    selectedEntry = firstEntry
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

  /// Prune the optimistic-read set down to IDs that still appear in the
  /// MainActor `unreadEntries` snapshot. Called whenever the snapshot
  /// changes — typically right after a `DataWriter` save propagates via
  /// SwiftData's auto-merge. IDs whose corresponding `Entry.isRead` has
  /// just flipped to `true` (or whose entry was deleted) fall out here;
  /// the sidebar's pending-aware aggregation then sees no double-counting.
  private func prunePendingReadIDs() {
    guard !pendingReadIDs.isEmpty else { return }
    let currentUnreadIDs = Set(unreadEntries.map(\.feedbinEntryID))
    pendingReadIDs.formIntersection(currentUnreadIDs)
  }

  private func markAllAsRead() {
    // Target the category the user currently *sees* (renderedSelection), not the
    // sidebar's pending selection — these diverge for ~150 ms after a sidebar
    // arrow press while the article list is debounced. Using `selection` here
    // would mark the wrong category read during that window.
    guard articleFilter == .unread, let target = renderedSelection,
      let writer = syncEngine.writer
    else { return }
    selectedEntry = nil
    let markTarget: MarkReadTarget
    let optimisticIDs: Set<Int>
    // Compute the optimistic set on MainActor from the already-loaded
    // `unreadEntries` snapshot so the sidebar can drop to zero in the same
    // frame the article list empties — without waiting for the background
    // writer to commit and the MainActor `@Query` to observe the change.
    // Bounded by unread inventory (the `@Query` already filters at SQLite
    // level), so this filter is the same shape as the existing aggregation.
    switch target {
    case .folder(let label):
      markTarget = .folder(label)
      optimisticIDs = Set(
        unreadEntries.lazy.filter { $0.primaryFolder == label }.map(\.feedbinEntryID)
      )
    case .category(let label):
      markTarget = .category(label)
      optimisticIDs = Set(
        unreadEntries.lazy.filter { $0.primaryCategory == label }.map(\.feedbinEntryID)
      )
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

  @ViewBuilder
  private var sidebarView: some View {
    // Lift aggregation out of computed properties: a computed `var` re-runs on
    // every access, and SwiftUI accesses it once per row inside `ForEach`
    // closures. Local `let`s in the body run once per body evaluation and the
    // dictionaries are then passed by reference into the row builders.
    //
    // `pendingReadIDs` is the optimistic-read overlay that already drives the
    // dimmed state in `EntryRowView`. Subtracting it from the sidebar counts
    // here keeps the badges in step with the article list in the same frame
    // — no need to flip `isRead` eagerly and defeat the flush debounce.
    let categoryUnreadCounts = unreadCounts(
      in: unreadEntries.map {
        UnreadCountInput(label: $0.primaryCategory, feedbinEntryID: $0.feedbinEntryID)
      },
      excludingFeedbinEntryIDs: pendingReadIDs
    )
    let folderUnreadCounts = unreadCounts(
      in: unreadEntries.map {
        UnreadCountInput(label: $0.primaryFolder, feedbinEntryID: $0.feedbinEntryID)
      },
      excludingFeedbinEntryIDs: pendingReadIDs
    )
    let groups = visibleFolderGroups

    List(selection: $selection) {
      Section {
        ForEach(groups, id: \.folder.persistentModelID) { group in
          sidebarFolderGroup(
            folder: group.folder,
            categories: group.categories,
            folderUnreadCounts: folderUnreadCounts,
            categoryUnreadCounts: categoryUnreadCounts
          )
        }
        ForEach(rootCategories) { category in
          sidebarCategoryRow(category: category, categoryUnreadCounts: categoryUnreadCounts)
        }
      } header: {
        SyncStatusView()
      }
    }
    .listStyle(.sidebar)
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

  /// A folder row plus its child categories rendered as a `DisclosureGroup`.
  /// The label carries the folder selection tag so the folder aggregate stays
  /// selectable (J/K nav and click). The trailing unread count is a
  /// `SidebarUnreadBadge` rather than `.badge(_:)` so we control its font
  /// and contrast — `.badge` renders a high-contrast system pill on macOS
  /// that has no public styling hook and clashed with the calm reader
  /// surface (`docs/vision.md`). Unread counts are passed in as
  /// already-computed dictionaries so the row builder never re-aggregates
  /// per render.
  @ViewBuilder
  private func sidebarFolderGroup(
    folder: Folder,
    categories: [Category],
    folderUnreadCounts: [String: Int],
    categoryUnreadCounts: [String: Int]
  ) -> some View {
    DisclosureGroup(
      isExpanded: SidebarCollapsedFolders.expansionBinding(
        for: folder.label, store: $collapsedFolders
      )
    ) {
      ForEach(categories) { category in
        sidebarCategoryRow(category: category, categoryUnreadCounts: categoryUnreadCounts)
      }
    } label: {
      sidebarRowLabel(
        title: folder.displayName,
        count: folderUnreadCounts[folder.label, default: 0]
      )
      .tag(SidebarSelection.folder(folder.label))
      .accessibilityIdentifier("sidebar.folder.\(folder.label)")
    }
  }

  /// A single selectable category row with its unread badge. Shared by
  /// in-folder children and root-level categories.
  @ViewBuilder
  private func sidebarCategoryRow(
    category: Category,
    categoryUnreadCounts: [String: Int]
  ) -> some View {
    sidebarRowLabel(
      title: category.displayName,
      count: categoryUnreadCounts[category.label, default: 0]
    )
    .tag(SidebarSelection.category(category.label))
    .accessibilityIdentifier("sidebar.category.\(category.label)")
  }

  /// Shared row layout for sidebar entries — folder labels and category
  /// labels both need "title left, quiet count right". Lifting this avoids
  /// duplicating the `HStack` + `Spacer()` + `SidebarUnreadBadge` triplet
  /// in two call sites and gives the count a stable trailing column.
  @ViewBuilder
  private func sidebarRowLabel(title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(fontSettings.body)
        .lineLimit(1)
      Spacer(minLength: 4)
      SidebarUnreadBadge(count: count)
    }
  }

  /// The navigation title reflects what the content column is currently rendering
  /// (`renderedSelection`), not the sidebar's pending selection (`selection`).
  /// During the 150 ms debounce window these differ — reading `renderedSelection`
  /// keeps the title aligned with the list the user actually sees.
  private var navigationTitle: String {
    switch renderedSelection {
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
      if let renderedEntry {
        EntryDetailView(entry: renderedEntry, viewMode: articleViewMode)
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
    if isPreviewMode {
      // Preview canvases seed their model container directly and never run
      // `startSync`/`configure`, so `syncEngine.writer` stays nil and
      // `EntryListView` would otherwise spin on `ProgressView` forever.
      // Attach a writer so the preview renders its seeded rows.
      let container = modelContext.container
      Task {
        let writer = await DataWriter.makeDetached(modelContainer: container)
        syncEngine.attachWriter(writer)
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
      startSync()
    }
  }

  private func seedUITestDataIfNeeded() {
    let container = modelContext.container
    Task {
      // Build the writer via the shared helper so `EntryListView` can
      // render the seeded rows (without a writer the demo-mode launch
      // sticks on `ProgressView`).
      let writer = await DataWriter.makeDetached(modelContainer: container)
      syncEngine.attachWriter(writer)
      let seeded = try? await writer.seedUITestData()
      if seeded == true {
        selection = .folder("technology")
      }
    }
  }

  private func startSync() {
    let username = UserDefaults.standard.string(forKey: feedbinUsernameUserDefaultsKey) ?? ""
    let password = KeychainHelper.load(key: KeychainHelper.feedbinPasswordKey) ?? ""
    guard !username.isEmpty, !password.isEmpty else { return }

    // `FeederApp.runBootstrap()` has already attached the production writer
    // before this view renders, so we only configure credentials here.
    syncEngine.configure(username: username, password: password)

    Task {
      // Purge entries older than 30 days (max setting). The article-list
      // fetch also passes `cutoffDate` to `DataWriter.fetchEntrySections`
      // so purged rows never appear in the UI even before the next refresh.
      if let writer = syncEngine.writer {
        let cutoff = Date().addingTimeInterval(-maxRetentionAge)
        try? await writer.purgeEntriesOlderThan(cutoff)
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
