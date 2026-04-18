import Foundation
import SwiftData
import SwiftUI

// MARK: - Article Filter

enum ArticleFilter: String, CaseIterable {
  case unread = "Unread"
  case read = "Read"
}

// MARK: - Pending Read IDs Environment Key

private struct PendingReadIDsKey: EnvironmentKey {
  static let defaultValue: Set<Int> = []
}

extension EnvironmentValues {
  var pendingReadIDs: Set<Int> {
    get { self[PendingReadIDsKey.self] }
    set { self[PendingReadIDsKey.self] = newValue }
  }
}

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
  case folder(String)
  case category(String)

  var isCategory: Bool {
    if case .category = self { return true }
    return false
  }
}

// MARK: - Panel Focus

private enum PanelFocus: Hashable {
  case sidebar
  case articleList
}

// MARK: - Mark All Read Key Handler

/// Intercepts Shift+A before List type-to-select can capture it.
private struct MarkAllReadKeyHandler: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .onKeyPress(characters: CharacterSet(charactersIn: "A")) { _ in
        action()
        return .handled
      }
  }
}

// MARK: - Bare Key Actions Environment

/// Actions for bare-key shortcuts that must fire from any panel,
/// intercepting before List type-to-select consumes letter keys.
/// Returns `KeyPress.Result` so individual actions can decline handling.
private struct BareKeyActions {
  var onJ: () -> KeyPress.Result = { .handled }
  var onK: () -> KeyPress.Result = { .handled }
  var onR: () -> KeyPress.Result = { .handled }
  var onB: () -> KeyPress.Result = { .handled }
}

private struct BareKeyActionsKey: EnvironmentKey {
  static let defaultValue = BareKeyActions()
}

extension EnvironmentValues {
  fileprivate var bareKeyActions: BareKeyActions {
    get { self[BareKeyActionsKey.self] }
    set { self[BareKeyActionsKey.self] = newValue }
  }
}

/// Intercepts bare-key shortcuts on each panel's List/view, preventing
/// List type-to-select from consuming them.
private struct BareKeyHandler: ViewModifier {
  @Environment(\.bareKeyActions)
  private var actions

  func body(content: Content) -> some View {
    content
      .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in actions.onJ() }
      .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in actions.onK() }
      .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in actions.onR() }
      .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in actions.onB() }
  }
}

// MARK: - Category-Folder-Change Refresh Trigger

/// Fires `onChange` when any category's `folderLabel` changes. Extracted into
/// a modifier so the category-folder-move refetch trigger doesn't push
/// ContentView.body past the type-checker's reasonable-time limit.
private struct CategoryFolderChangeTrigger: ViewModifier {
  let categoryFolderLabels: [String?]
  let onChange: () -> Void

  func body(content: Content) -> some View {
    content.onChange(of: categoryFolderLabels) {
      onChange()
    }
  }
}

// MARK: - Visible Entry IDs Preference Key

/// Bubbles the current entry IDs from EntryListView up to ContentView
/// so Tab can select the first article when switching to the article list.
/// Carries `PersistentIdentifier`s (Sendable, lightweight) — the Tab handler
/// materializes the first Entry on demand via `modelContext.model(for:)`.
private struct VisibleEntryIDsKey: PreferenceKey {
  static let defaultValue: [PersistentIdentifier] = []
  static func reduce(value: inout [PersistentIdentifier], nextValue: () -> [PersistentIdentifier]) {
    value = nextValue()
  }
}

// MARK: - Entry List View (background-fetched section snapshots, no MainActor @Query)

/// Renders the article list for a given sidebar selection.
///
/// **Why not `@Query`**: SwiftData's `@Query` runs synchronously on MainActor
/// during view init/body. For large categories (e.g. "uncategorized" with
/// thousands of entries), the SQLite fetch + Entry materialization + day-grouping
/// blocks the main thread for seconds — even a `ProgressView` placeholder
/// can't paint because MainActor is busy.
///
/// Instead, the heavy fetch + grouping runs on `DataWriter` (a `@ModelActor`,
/// so on a background thread). The view holds lightweight `[EntryListSection]`
/// state (`PersistentIdentifier` arrays + section labels — Sendable DTOs) and
/// shows `ProgressView` instantly while the fetch runs. Each row materializes
/// its `Entry` lazily on MainActor via `modelContext.model(for:)` (cheap O(1)
/// primary-key lookup, only for visible rows).
///
/// **Live updates**: lost compared to `@Query` auto-refresh. Replaced by
/// explicit refresh-version triggers driven from `ContentView` — `.onChange`
/// handlers on `syncEngine.isSyncing` / `classificationEngine.isClassifying`
/// false-transitions, plus an explicit bump after `flushPendingReads` and
/// `markAllAsRead` writes.
struct EntryListView: View {
  let category: String?
  let folder: String?
  let filter: ArticleFilter
  let cutoffDate: Date
  let writer: DataWriter
  let refreshVersion: Int
  @Binding
  var selectedEntry: Entry?
  let onMarkAllRead: () -> Void

  @Environment(\.modelContext)
  private var modelContext
  @State
  private var sections: [EntryListSection] = []
  /// Flattened entry IDs cached for the `VisibleEntryIDsKey` preference. Computed once
  /// per fetch (in `.task`) instead of `sections.flatMap(\.entryIDs)` on every body
  /// re-eval — meaningful for large categories ("uncategorized" with thousands of IDs).
  @State
  private var allVisibleEntryIDs: [PersistentIdentifier] = []
  @State
  private var hasLoaded = false

  var body: some View {
    Group {
      if !hasLoaded {
        ProgressView()
          .controlSize(.regular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("timeline.loading")
      } else if sections.isEmpty {
        ContentUnavailableView {
          Label("No Articles", systemImage: "newspaper")
        } description: {
          Text(
            filter == .unread
              ? "No unread articles in this category."
              : "No read articles in this category."
          )
        }
      } else {
        List(selection: $selectedEntry) {
          ForEach(sections) { section in
            Section {
              ForEach(section.entryIDs, id: \.self) { id in
                if let entry = modelContext.model(for: id) as? Entry {
                  EntryRowView(entry: entry)
                    .tag(entry)
                    .listRowSeparator(.hidden)
                }
              }
            } header: {
              Text(section.label)
                .font(.system(size: FontTheme.captionSize, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(nil)
            }
          }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .modifier(BareKeyHandler())
        .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
        .preference(key: VisibleEntryIDsKey.self, value: allVisibleEntryIDs)
        .accessibilityIdentifier("timeline.list")
      }
    }
    // Two tasks so refresh-only ticks (classification / sync completion) do
    // not flip `hasLoaded` back to false and tear down the `List` — which
    // would reset scroll every time. `structuralKey` captures inputs whose
    // change means "user is looking at a different list" (category / folder
    // / filter / cutoff); only those warrant a loading view. `refreshVersion`
    // fires in place and `reload()` skips the assign when sections are
    // equal, so SwiftUI's diff keeps the scroll stable.
    //
    // The refresh task's id intentionally includes `structuralKey`: a bare
    // `refreshVersion` id would not be cancelled when the user switches
    // category mid-refresh, and the in-flight fetch — which captured `self`
    // with the old category — could race the structural task and overwrite
    // `sections` with stale rows from the previous list. Including
    // `structuralKey` cancels the stale refresh when context changes, and
    // the `guard hasLoaded` check keeps the restarted refresh a no-op while
    // the structural task owns the reload.
    .task(id: structuralKey) {
      hasLoaded = false
      await reload()
      hasLoaded = true
    }
    .task(id: refreshTaskKey) {
      guard hasLoaded else { return }
      await reload()
    }
  }

  private func reload() async {
    let result =
      (try? await writer.fetchEntrySections(
        category: category, folder: folder, showRead: filter == .read, cutoffDate: cutoffDate
      )) ?? []
    guard !Task.isCancelled else { return }
    if result != sections {
      sections = result
      allVisibleEntryIDs = result.flatMap(\.entryIDs)
    }
  }

  /// Composed key for the refresh task so a structural change (category /
  /// folder / filter / cutoff) cancels any in-flight refresh bound to the
  /// previous context. Without the structural suffix, a refresh captured
  /// against the old `self` could finish after the structural reload and
  /// overwrite `sections` with stale rows.
  private var refreshTaskKey: String {
    "\(structuralKey)|\(refreshVersion)"
  }

  /// Key for "this is a different article list" — user-visible context change.
  /// Excludes `refreshVersion`, which rides on a separate task so in-place
  /// refreshes do not tear down the `List` and drop the scroll position.
  private var structuralKey: String {
    "\(category ?? "")|\(folder ?? "")|\(filter.rawValue)|\(cutoffDate.timeIntervalSince1970)"
  }
}

// MARK: - Sync Status View (isolated from article list to prevent unnecessary re-renders)

struct SyncStatusView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine

  private var lastSyncText: String? {
    guard let date = syncEngine.lastSyncDate else { return nil }
    let calendar = Calendar.current
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    if calendar.isDateInToday(date) {
      return "Synced today \(time)"
    } else if calendar.isDateInYesterday(date) {
      return "Synced yesterday \(time)"
    } else {
      return "Synced \(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
    }
  }

  private var fetchStatusText: String? {
    if syncEngine.isSyncing {
      let n = syncEngine.fetchedCount
      let x = syncEngine.totalToFetch
      return x > 0 ? "Fetching \(n)/\(x)" : "Syncing..."
    }
    return lastSyncText
  }

  private var classifyStatusText: String? {
    guard classificationEngine.isClassifying else { return nil }
    let n = classificationEngine.classifiedCount
    let x = classificationEngine.totalToClassify
    return x > 0 ? "Categorizing \(n)/\(x)" : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("News")
        .font(.system(size: FontTheme.sectionHeaderSize, weight: .bold))
        .foregroundStyle(.primary)
        .textCase(nil)

      if let fetchStatus = fetchStatusText {
        Text(fetchStatus)
          .font(.system(size: FontTheme.statusSize))
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
      if let classifyStatus = classifyStatusText {
        Text(classifyStatus)
          .font(.system(size: FontTheme.statusSize))
          .foregroundStyle(.tertiary)
          .textCase(nil)
          .contentTransition(.numericText())
      }
    }
    .padding(.bottom, 4)
  }
}

// MARK: - Content View

struct ContentView: View {
  /// Dwell time before propagating a keyboard-driven selection change to a heavy
  /// downstream view (WebView render or article-list background fetch). Short
  /// enough that single intentional taps still feel instant; long enough to
  /// suppress per-keystroke work during arrow-key scrubbing.
  fileprivate static let renderDwell: Duration = .milliseconds(150)

  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(\.modelContext)
  private var modelContext
  @Environment(\.scenePhase)
  private var scenePhase
  @Query(sort: \Folder.sortOrder)
  private var folders: [Folder]
  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]
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
  @State
  private var entryRefreshVersion: Int = 0
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
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: renderedSelection)
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
        entryRefreshVersion &+= 1
      }
    }
    .onChange(of: classificationEngine.isClassifying) { _, isClassifying in
      if !isClassifying && classificationEngine.lastBatchClassifiedCount > 0 {
        entryRefreshVersion &+= 1
      }
    }
    .modifier(
      CategoryFolderChangeTrigger(
        categoryFolderLabels: categoryFolderLabels,
        onChange: { entryRefreshVersion &+= 1 }
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
    .onKeyPress(characters: CharacterSet(charactersIn: "jJ")) { _ in bareKeyActions.onJ() }
    .onKeyPress(characters: CharacterSet(charactersIn: "kK")) { _ in bareKeyActions.onK() }
    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in bareKeyActions.onR() }
    .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in bareKeyActions.onB() }
    .modifier(menuBarValues)
  }

  // Separated to keep body type-checkable
  private var menuBarValues: some ViewModifier {
    FocusedValuesModifier(
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
  }

  // MARK: - Category lookups (small count, acceptable in-memory filter)

  private var rootCategories: [Category] { allCategories.atRoot }

  /// Flat ordered sidebar items matching visual display order.
  private var sidebarItems: [SidebarSelection] {
    var items: [SidebarSelection] = []
    for folder in folders {
      items.append(.folder(folder.label))
      for category in allCategories.inFolder(folder.label) {
        items.append(.category(category.label))
      }
    }
    for category in rootCategories {
      items.append(.category(category.label))
    }
    return items
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
  /// moving a category between folders (via DataWriter.moveCategoryToFolder /
  /// batchUpdateCategoryFolderAndSortOrders) refreshes the article list.
  /// Extracted from body to keep the type-checker happy.
  private var categoryFolderLabels: [String?] {
    allCategories.map(\.folderLabel)
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

  private func flushPendingReads() {
    let ids = pendingReadIDs
    guard !ids.isEmpty else { return }
    pendingReadIDs.removeAll()
    syncEngine.queueReadIDs(ids)
    Task {
      guard let writer = syncEngine.writer else { return }
      try? await writer.markEntriesRead(feedbinEntryIDs: ids)
      // Locally mutating isRead invalidates the article-list snapshot — refetch
      // so unread filter shrinks. Without this, scrubbed-past entries linger
      // (only dimmed via pendingReadIDs) until the next sync/classification.
      entryRefreshVersion &+= 1
    }
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
    switch target {
    case .folder(let label): markTarget = .folder(label)
    case .category(let label): markTarget = .category(label)
    }
    Task {
      let markedIDs = try? await writer.markAllAsRead(
        target: markTarget, cutoffDate: syncEngine.queryCutoffDate
      )
      guard let ids = markedIDs, !ids.isEmpty else { return }
      syncEngine.queueReadIDs(ids)
      // Same rationale as flushPendingReads — refetch so the now-empty unread
      // list (or remaining unread items) appears immediately.
      entryRefreshVersion &+= 1
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
    List(selection: $selection) {
      Section {
        ForEach(folders) { folder in
          Text(folder.displayName)
            .font(.system(size: FontTheme.metadataSize, weight: .semibold))
            .tag(SidebarSelection.folder(folder.label))
            .accessibilityIdentifier("sidebar.folder.\(folder.label)")
          ForEach(allCategories.inFolder(folder.label)) { category in
            Text(category.displayName)
              .font(.system(size: FontTheme.metadataSize))
              .padding(.leading, 16)
              .tag(SidebarSelection.category(category.label))
              .accessibilityIdentifier("sidebar.category.\(category.label)")
          }
        }
        ForEach(rootCategories) { category in
          Text(category.displayName)
            .font(.system(size: FontTheme.metadataSize))
            .tag(SidebarSelection.category(category.label))
            .accessibilityIdentifier("sidebar.category.\(category.label)")
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
      Task { await syncEngine.attachWriter(modelContainer: container) }
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

    let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
    let password = KeychainHelper.load(key: "feedbin_password") ?? ""
    if username.isEmpty || password.isEmpty {
      needsSetup = true
    } else {
      startSync()
    }
  }

  private func seedUITestDataIfNeeded() {
    let container = modelContext.container
    Task {
      // Reuse the production writer-attach path — fixes the "DataWriter init on
      // MainActor" violation and ensures `syncEngine.writer` is populated so
      // `EntryListView` can render the seeded rows (without it the demo-mode
      // launch sticks on `ProgressView`).
      await syncEngine.attachWriter(modelContainer: container)
      guard let writer = syncEngine.writer else { return }
      let seeded = try? await writer.seedUITestData()
      if seeded == true {
        selection = .folder("technology")
      }
    }
  }

  private func startSync() {
    let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
    let password = KeychainHelper.load(key: "feedbin_password") ?? ""
    guard !username.isEmpty, !password.isEmpty else { return }

    let container = modelContext.container
    Task {
      await syncEngine.configure(username: username, password: password, modelContainer: container)

      // Purge entries older than 30 days (max setting). The article-list
      // fetch also passes `cutoffDate` to `DataWriter.fetchEntrySections`
      // so purged rows never appear in the UI even before the next refresh.
      if let writer = syncEngine.writer {
        let cutoff = Date().addingTimeInterval(-maxRetentionAge)
        try? await writer.purgeEntriesOlderThan(cutoff)
      }

      let syncInterval = UserDefaults.standard.double(forKey: "sync_interval").clamped(to: 60...3600, default: 300)
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
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard let container = try? ModelContainer(for: Entry.self, Feed.self, Category.self, Folder.self, configurations: config) else {
    fatalError("Preview ModelContainer failed")
  }
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
    .modelContainer(container)
    .frame(minWidth: 1200, minHeight: 760)
}
