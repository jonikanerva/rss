import Foundation
import SwiftData
import SwiftUI

// MARK: - Color extension

extension Color {
  init(hex: UInt, opacity: Double = 1.0) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

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

// MARK: - Date Section Helpers

// Note: section label + day grouping moved to `DataWriter.swift` so the
// heavy fetch + grouping work runs off MainActor.

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
/// explicit refresh-version triggers driven from `ContentView`'s `.onChange`
/// handlers on `syncEngine.lastSyncDate` and `classificationEngine.isClassifying`.
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
        .preference(key: VisibleEntryIDsKey.self, value: sections.flatMap(\.entryIDs))
        .accessibilityIdentifier("timeline.list")
      }
    }
    .task(id: fetchKey) {
      hasLoaded = false
      let result =
        (try? await writer.fetchEntrySections(
          category: category, folder: folder, showRead: filter == .read, cutoffDate: cutoffDate
        )) ?? []
      guard !Task.isCancelled else { return }
      sections = result
      hasLoaded = true
    }
  }

  /// Keying the `.task` on this string causes SwiftUI to cancel the in-flight
  /// fetch and start a fresh one whenever any input changes — including
  /// `refreshVersion`, which `ContentView` bumps on sync/classification events.
  private var fetchKey: String {
    "\(category ?? "")|\(folder ?? "")|\(filter.rawValue)|\(cutoffDate.timeIntervalSince1970)|\(refreshVersion)"
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
  /// `selection`, so rapid sidebar arrow scrubbing doesn't tear down + rebuild
  /// `EntryListView` (and its `@Query` SQLite fetch + `groupedByDay` work) on
  /// every keystroke. Driven by `.task(id: selection)` after a short dwell time.
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
      // Debounce: WebView only loads HTML for entries the user dwells on for >150 ms.
      // When selectedEntry changes again before the sleep completes, this task is
      // cancelled and the in-flight load is skipped — so holding Down arrow no
      // longer triggers N WebKit reloads + buildHTML cycles on MainActor.
      guard selectedEntry != nil else { return }
      try? await Task.sleep(for: .milliseconds(150))
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
      // Debounce: the article-list `EntryListView` (with its `@Query` SQLite
      // fetch + `groupedByDay` work on MainActor) is only created for sidebar
      // selections the user dwells on for >150 ms. Holding Up/Down through
      // 10 categories no longer triggers 10 sequential SwiftData fetches —
      // only the final selection's list builds.
      guard selection != nil else { return }
      try? await Task.sleep(for: .milliseconds(150))
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
    // Both triggers fire on the false transition (work just finished) —
    // the per-tick progress properties (`fetchedCount`, `classifiedCount`)
    // would cause excessive refetches if used as the trigger instead.
    .onChange(of: syncEngine.isSyncing) { _, isSyncing in
      if !isSyncing {
        entryRefreshVersion &+= 1
      }
    }
    .onChange(of: classificationEngine.isClassifying) { _, isClassifying in
      if !isClassifying {
        entryRefreshVersion &+= 1
      }
    }
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
        // Materialize the first visible entry on demand (lazy primary-key
        // lookup on MainActor — the list itself only carries `PersistentIdentifier`s).
        if let firstID = currentEntryIDs.first,
          let firstEntry = modelContext.model(for: firstID) as? Entry
        {
          selectedEntry = firstEntry
        }
        panelFocus = .articleList
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
      canMarkAllRead: articleFilter == .unread && selection != nil,
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
      switch sel {
      case .folder(let label):
        EntryListView(
          category: nil, folder: label, filter: articleFilter,
          cutoffDate: syncEngine.queryCutoffDate, writer: writer,
          refreshVersion: entryRefreshVersion,
          selectedEntry: $selectedEntry, onMarkAllRead: markAllAsRead
        )
      case .category(let label):
        EntryListView(
          category: label, folder: nil, filter: articleFilter,
          cutoffDate: syncEngine.queryCutoffDate, writer: writer,
          refreshVersion: entryRefreshVersion,
          selectedEntry: $selectedEntry, onMarkAllRead: markAllAsRead
        )
      }
    } else {
      // SyncEngine.configure hasn't completed yet (first launch path).
      // Show a spinner — the configure Task will populate writer shortly.
      ProgressView()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Selection

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
    }
  }

  private func markAllAsRead() {
    guard articleFilter == .unread, let selection, let writer = syncEngine.writer else { return }
    selectedEntry = nil
    Task {
      let markedIDs: Set<Int>?
      switch selection {
      case .folder(let label):
        markedIDs = try? await writer.markAllAsRead(folder: label, cutoffDate: syncEngine.queryCutoffDate)
      case .category(let label):
        markedIDs = try? await writer.markAllAsRead(category: label, cutoffDate: syncEngine.queryCutoffDate)
      }
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
    if isPreviewMode { return }
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
    let writer = DataWriter(modelContainer: modelContext.container)
    Task {
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

      // Purge entries older than 30 days (max setting) — @Query date filter handles visibility
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
