import Foundation
import SwiftData
import SwiftUI
import os.signpost

// MARK: - Content View

struct ContentView: View {
  /// The window reads and writes the store only through these actors.
  let store: StoreActors
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
  /// Refresh scheduling and read intents of this window.
  @State
  private var timeline: TimelineState
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
  /// materialization per selection. Write it only in the
  /// `.onChange(of: selectedEntryID)` handler and in `AccountSwitchWindowReset`;
  /// every other consumer only reads it.
  @State
  private var selectedEntry: Entry?
  @State
  private var selection: SidebarSelection?
  @State
  private var articleFilter: ArticleFilter = .unread
  @State
  private var search = ArticleSearchState()
  @State
  private var articleViewMode: ArticleViewMode = .web
  @State
  private var detailPageCommand = DetailPageCommand.initial
  /// A bump asks the article list for the row that Tab selects.
  @State
  private var articleListTabRequest = 0
  /// App-lifetime favicon cache: decoded once per feed, off the render path.
  @State
  private var faviconStore = FaviconStore()
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
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(store: StoreActors, readQueue: SyncEngine) {
    self.store = store
    _timeline = State(initialValue: TimelineState(store: store, readQueue: readQueue))
  }

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
          VStack(spacing: 0) {
            if search.isPresented {
              ArticleSearchBar(state: search, onSubmit: tabIntoArticleList, onCancel: closeSearch)
            }
            entryListForSelection(selection)
              // An empty list must still fill the column, so the bar stays
              // under the toolbar.
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .focused($panelFocus, equals: .articleList)
              // Only the list: the detail pane, the web view, and a text field
              // keep their own Copy.
              .onCommand(
                #selector(NSText.copy(_:)),
                perform: articleLinkCopyAction(url: selectedEntryURL) { NSPasteboard.general.writeLink($0) }
              )
          }
          .environment(\.pendingReadIDs, timeline.pendingReadIDs)
          .environment(\.pendingUnreadIDs, timeline.pendingUnreadIDs)
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
            ToolbarItem(placement: .automatic) {
              Button {
                toggleSearch()
              } label: {
                Label("Search", systemImage: "magnifyingglass")
              }
              .help("Search this list (⌘F)")
              .accessibilityIdentifier("toolbar.search")
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
      timeline.visibleEntriesChanged(renderedUnreadIDs: payload.unreadFeedbinEntryIDs)
    }
    .task(id: contentReevalVersion) {
      guard let state = contentReevalIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.contentViewReeval, state)
      contentReevalIntervalState = nil
    }
    .onAppear {
      // Runs for each new main window: at launch, and after a Dock click
      // reopens a closed window. Every step here is safe to repeat.
      ColumnWidthDiagnostics.logRestoredIdeal(sidebarIdealWidth, for: .sidebar)
      ColumnWidthDiagnostics.logRestoredIdeal(contentColumnIdealWidth, for: .content)
      bootLaunchMode()
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
    .modifier(FeedbinAccountLifecycle(startSync: startSync))
    .onChange(of: selectedEntryID) { _, newID in
      // The single writer for `selectedEntry`: resolve the one live model per
      // selection commit here, at the interface↔store boundary. Every other
      // consumer reads the memoized `@State`.
      // A row of an entry that an account switch deleted can stay until the
      // list refreshes. Its model must not be read.
      let newEntry = newID.flatMap { syncEngine.isDeletedEntry($0) ? nil : modelContext.model(for: $0) as? Entry }
      selectedEntry = newEntry
      // Mark-read reads the live `entry.isRead`, which is fresher than the
      // row DTO's snapshot.
      if let entry = newEntry {
        timeline.entrySelected(feedbinEntryID: entry.feedbinEntryID, isRead: entry.isRead)
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
      timeline.flushPendingReads(.filterChange)
      selectedEntryID = nil
    }
    .onChange(of: selection) { _, newSelection in
      // No list refresh: the sidebar move re-keys the structural task, whose
      // first page covers the new axis.
      timeline.flushPendingReads(.sidebarChange)
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
    .onDisappear {
      // The window closed. The app keeps running, so the reads go to the store
      // and to Feedbin now, not at the quit.
      timeline.windowClosed()
      Task { await syncEngine.pushPendingReads() }
    }
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        timeline.sceneBecameActive()
      } else {
        timeline.flushPendingReads(.sceneInactive)
        Task { await syncEngine.pushPendingReads() }
      }
    }
    .modifier(
      TimelineRefreshTasks(
        timeline: timeline,
        cutoffDate: syncEngine.queryCutoffDate,
        folderCount: folders.count,
        categoryCount: allCategories.count,
        selectedFeedbinEntryID: selectedEntry?.feedbinEntryID
      )
    )
    .modifier(
      AccountSwitchWindowReset(
        timeline: timeline, selectedEntryID: $selectedEntryID, selectedEntry: $selectedEntry)
    )
    .modifier(TimelineSignalRouterModifier(timeline: timeline))
    .modifier(
      CategoryFolderChangeTrigger(
        categoryFolderLabels: categoryFolderLabels,
        onChange: { timeline.categoryFoldersChanged() }
      )
    )
    // Escape and Tab stay at `NavigationSplitView` level so `List`
    // type-to-select cannot consume them.
    .onKeyPress(.escape) {
      if search.isPresented, isTypingInArticleSearch() {
        closeSearch()
        return .handled
      }
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
    // J/K/R/B/M/C route three ways. The per-panel `BareKeyHandler` modifiers fire
    // while a `List` has focus and keep bare keys out of text fields, where
    // typing must type. `BareKeyForwardingWebView` forwards the same actions
    // from inside the article web view, where the AppKit first responder
    // swallows key events. This root fallback covers every state in which no
    // focusable surface holds focus.
    .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onJ() }
    .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onK() }
    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onR() }
    .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onB() }
    .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onM() }
    .onKeyPress(characters: CharacterSet(charactersIn: "cC")) { _ in isTypingInArticleSearch() ? .ignored : bareKeyActions.onC() }
    .modifier(menuBarValues)
  }

  // Separated to keep body type-checkable
  private var menuBarValues: some ViewModifier {
    FocusedValuesModifier(
      context: FeederCommandContext(
        syncAction: { Task { await syncAndClassify() } },
        markAllReadAction: markAllAsRead,
        findAction: toggleSearch,
        toggleViewModeAction: toggleArticleViewMode,
        toggleFilterAction: toggleArticleFilter,
        openInBrowserAction: openInBackground,
        copyLinkAction: copySelectedLink,
        toggleReadAction: toggleSelectedEntryRead,
        moveSelectionDownAction: { moveSidebarSelection(by: 1) },
        moveSelectionUpAction: { moveSidebarSelection(by: -1) },
        canMarkAllRead: articleFilter == .unread && selection != nil,
        canOpenInBrowser: selectedEntry != nil,
        hasSelectedEntry: selectedEntry != nil,
        selectedEntryIsRead: selectedEntry.map {
          timeline.isRead(feedbinEntryID: $0.feedbinEntryID, storeIsRead: $0.isRead)
        },
        isSyncing: syncEngine.isSyncing || classificationEngine.isClassifying,
        currentViewMode: articleViewMode,
        currentFilter: articleFilter,
        hasSidebarSelection: selection != nil
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

  private func pageDetail(modifiers: EventModifiers) -> KeyPress.Result {
    guard let direction = detailPageDirection(hasSelectedEntry: selectedEntry != nil, modifiers: modifiers)
    else { return .ignored }
    detailPageCommand = detailPageCommand.next(direction)
    return .handled
  }

  private func toggleArticleViewMode() {
    articleViewMode = articleViewMode == .web ? .reader : .web
  }

  /// The filter picker shows only with a sidebar selection, so the toggle
  /// needs one too.
  private func toggleArticleFilter() {
    guard selection != nil else { return }
    articleFilter = articleFilter.toggled
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
      },
      onM: {
        guard selectedEntry != nil else { return .ignored }
        toggleSelectedEntryRead()
        return .handled
      },
      onC: {
        guard selectedEntryURL != nil else { return .ignored }
        copySelectedLink()
        return .handled
      },
      onU: {
        guard selection != nil else { return .ignored }
        toggleArticleFilter()
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
    EntryListView(
      scope: sel.entryScope, filter: articleFilter, search: search.term,
      cutoffDate: syncEngine.queryCutoffDate, reader: store.reader,
      refreshVersion: timeline.listVersion,
      accountDataVersion: timeline.accountDataVersion,
      pinnedFeedbinEntryID: selectedEntry?.feedbinEntryID,
      selectedEntryID: entrySelectionBinding, onMarkAllRead: markAllAsRead,
      isRead: timeline.isRead(feedbinEntryID:storeIsRead:),
      onToggleRead: toggleRowRead(_:),
      onPageDetail: pageDetail(modifiers:),
      tabSelectionRequest: articleListTabRequest,
      onTabSelection: { selectedEntryID = $0 }
    )
  }

  // MARK: - Selection

  /// Snapshot of every category's folder assignment. Watched so that moving a
  /// category between folders refreshes the article list.
  private var categoryFolderLabels: [String?] {
    allCategories.map(\.folderLabel)
  }

  /// Tab from the sidebar into the article-list column. The list keeps a
  /// selection that is on screen, or selects its first row on screen
  /// (`EntryListTabSelection`). Without such a row Tab moves focus alone.
  private func tabIntoArticleList() {
    panelFocus = .articleList
    articleListTabRequest &+= 1
  }

  /// The magnifier button and Command-F share this toggle.
  private func toggleSearch() {
    guard selection != nil else { return }
    let wasPresented = search.isPresented
    search.toggle()
    if wasPresented { panelFocus = .articleList }
  }

  private func closeSearch() {
    search.close()
    panelFocus = .articleList
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

  private func markAllAsRead() {
    guard let selection else { return }
    markAllAsRead(target: selection)
  }

  private func markAllAsRead(target: SidebarSelection) {
    guard articleFilter == .unread else { return }
    let plan = markAllReadPlan(
      for: target, currentSelection: selection, snapshot: timeline.unreadSnapshot,
      search: search.typedTerm)
    if plan.clearsArticleSelection {
      selectedEntryID = nil
    }
    timeline.markAllAsRead(plan)
  }

  private func openInBackground() {
    guard let url = selectedEntryURL else { return }
    NSWorkspace.shared.openInBackground(url)
  }

  private func copySelectedLink() {
    guard let url = selectedEntryURL else { return }
    NSPasteboard.general.writeLink(url)
  }

  private func toggleSelectedEntryRead() {
    guard let selectedEntry else { return }
    toggleRead(feedbinEntryID: selectedEntry.feedbinEntryID, storeIsRead: selectedEntry.isRead)
  }

  /// A row of an entry that an account switch deleted can stay until the list
  /// refreshes. Its ID belongs to the previous account, so it must not reach
  /// the read queues.
  private func toggleRowRead(_ row: EntryRowDTO) {
    guard !syncEngine.isDeletedEntry(row.persistentID) else { return }
    toggleRead(feedbinEntryID: row.feedbinEntryID, storeIsRead: row.isRead)
  }

  /// Toggle the read state that the window shows for one article.
  private func toggleRead(feedbinEntryID id: Int, storeIsRead: Bool) {
    if timeline.isRead(feedbinEntryID: id, storeIsRead: storeIsRead) {
      timeline.markUnread(feedbinEntryID: id)
    } else {
      timeline.markRead(feedbinEntryID: id)
    }
  }

  private var selectedEntryURL: URL? {
    selectedEntry.flatMap { entryLinkURL(from: $0.url) }
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
      snapshot: timeline.unreadSnapshot, pending: timeline.pendingReadIDs)
    let pendingByFolder = pendingReadCountsByFolder(
      snapshot: timeline.unreadSnapshot, pending: timeline.pendingReadIDs)
    let categoryUnreadCounts = timeline.unreadSnapshot.categoryCounts
      .subtractingPendingCounts(pendingByCategory)
    let folderUnreadCounts = timeline.unreadSnapshot.folderCounts
      .subtractingPendingCounts(pendingByFolder)
    let allArticlesUnreadCount = max(
      0, timeline.unreadSnapshot.totalUnread - pendingReadCountAll(snapshot: timeline.unreadSnapshot, pending: timeline.pendingReadIDs))
    // `EquatableView` short-circuits the sidebar body whenever the structural
    // inputs match the previous render, so overlay flips and detail-pane state
    // never reach the sidebar's render path. Toolbar and key handlers stay
    // outside the wrap so they keep observing the engines.
    EquatableView(
      content: SidebarView(
        allArticlesUnreadCount: allArticlesUnreadCount,
        visibleFolderGroups: sidebarFolderGroupSnapshots,
        rootCategories: sidebarRootCategorySnapshots,
        categoryUnreadCounts: categoryUnreadCounts,
        folderUnreadCounts: folderUnreadCounts,
        fontBody: fontSettings.body,
        canMarkAllRead: articleFilter == .unread,
        onMarkAllRead: markAllAsRead(target:),
        selection: sidebarSelectionBinding,
        collapsedFolders: $collapsedFolders
      )
    )
    .modifier(BareKeyHandler(handlesFilterKey: true))
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
    case .allArticles:
      return "All Articles"
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
        EntryDetailView(entry: selectedEntry, viewMode: articleViewMode, pageCommand: detailPageCommand)
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

  /// Must branch on exactly the launches for which
  /// `FeederApp.usesFeedbinAccount(in:)` is false, the headless launch and
  /// previews: each one gets the `.unused` account phase, so
  /// `FeedbinAccountLifecycle` never boots it.
  private func bootLaunchMode() {
    if HeadlessMode.isEnabled {
      bootHeadless()
      return
    }
    if isPreviewMode {
      // Preview canvases never run the bootstrap, so Mark All as Read needs
      // the writer here.
      syncEngine.attachWriter(store.writer)
    }
  }

  private func bootHeadless() {
    // Defence in depth: an inert client means no sync path can reach Feedbin.
    syncEngine.attachClient(InertFeedbinClient())
    seedUITestDataIfNeeded()
  }

  /// Seeds the data store: call it only on a launch with the in-memory store.
  private func seedUITestDataIfNeeded() {
    let writer = store.writer
    Task {
      let seeded = try? await writer.seedUITestData()
      if seeded == true {
        selection = .folder("technology")
      }
    }
  }

  private func startSync() {
    // Start the periodic sync before the first suspension: the start is the
    // claim that `startsSignedInSession` reads for every other main window.
    let syncInterval = AppDefaults.current.double(forKey: syncIntervalUserDefaultsKey).clamped(to: 60...3600, default: 300)
    syncEngine.startPeriodicSync(interval: syncInterval)
    Task {
      // The reads already filter on `publishedAt >= cutoffDate`, so this purge
      // only stops the store growing without bound. Passing the ceiling
      // derived from `maxRetentionAge` keeps a change to `articleKeepDays`
      // from needing a refetch and recategorise round-trip.
      let days = Int(maxRetentionAge / 86_400)
      _ = try? await store.writer.purgeEntriesOlderThan(days)
      classificationEngine.startContinuousClassification(writer: store.writer)
    }
  }

  private func syncAndClassify() async {
    await syncEngine.sync()
    await classificationEngine.classifyUnclassified(writer: store.writer)
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
    entry.plainText = "Sample article \(i)."
    context.insert(entry)
  }

  try? context.save()

  return ContentViewPreviewHost(container: container)
}

/// Builds the store actors for the preview container before the window exists,
/// as `FeederApp` does after its bootstrap.
private struct ContentViewPreviewHost: View {
  let container: ModelContainer
  @State
  private var syncEngine = SyncEngine.preview()
  @State
  private var store: StoreActors?

  var body: some View {
    Group {
      if let store {
        ContentView(store: store, readQueue: syncEngine)
      } else {
        ProgressView()
      }
    }
    .task {
      let writer = await DataWriter.makeDetached(modelContainer: container)
      let reader = await DataReader.makeDetached(modelContainer: container)
      store = StoreActors(writer: writer, reader: reader)
    }
    .environment(syncEngine)
    .environment(ClassificationEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(minWidth: 1200, minHeight: 760)
  }
}
