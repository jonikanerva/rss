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

/// Format a section header label for a given date.
private func sectionLabel(for date: Date) -> String {
  let calendar = Calendar.current
  if calendar.isDateInToday(date) {
    return "Today"
  } else if calendar.isDateInYesterday(date) {
    return "Yesterday"
  } else {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    let day = calendar.component(.day, from: date)
    let month = date.formatted(.dateTime.month(.wide))
    let year = date.formatted(.dateTime.year())
    return "\(weekday) \(day). \(month) \(year)"
  }
}

/// Group entries by calendar day (start of day), preserving order.
private func groupedByDay(_ entries: [Entry]) -> [(date: Date, label: String, entries: [Entry])] {
  let calendar = Calendar.current
  var groups: [(date: Date, label: String, entries: [Entry])] = []
  var currentDay: Date?
  var currentEntries: [Entry] = []

  for entry in entries {
    let day = calendar.startOfDay(for: entry.publishedAt)
    if day != currentDay {
      if let prevDay = currentDay, !currentEntries.isEmpty {
        groups.append((date: prevDay, label: sectionLabel(for: prevDay), entries: currentEntries))
      }
      currentDay = day
      currentEntries = [entry]
    } else {
      currentEntries.append(entry)
    }
  }
  if let lastDay = currentDay, !currentEntries.isEmpty {
    groups.append((date: lastDay, label: sectionLabel(for: lastDay), entries: currentEntries))
  }
  return groups
}

// MARK: - Entry List View (dynamic @Query filtered by category + read status in SQLite)

struct EntryListView: View {
  @Query
  private var entries: [Entry]
  @Binding
  var selectedEntry: Entry?
  private let filter: ArticleFilter

  init(category: String, filter: ArticleFilter, cutoffDate: Date, selectedEntry: Binding<Entry?>) {
    let showRead = filter == .read
    _entries = Query(
      filter: #Predicate<Entry> {
        $0.isClassified && $0.primaryCategory == category && $0.isRead == showRead
          && $0.publishedAt >= cutoffDate
      },
      sort: \Entry.publishedAt,
      order: .reverse
    )
    self.filter = filter
    _selectedEntry = selectedEntry
  }

  var body: some View {
    let sections = groupedByDay(entries)
    List(selection: $selectedEntry) {
      ForEach(sections, id: \.date) { section in
        Section {
          ForEach(section.entries) { entry in
            EntryRowView(entry: entry)
              .tag(entry)
              .listRowSeparator(.hidden)
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
    .accessibilityIdentifier("timeline.list")
    .overlay {
      if entries.isEmpty {
        ContentUnavailableView {
          Label("No Articles", systemImage: "newspaper")
        } description: {
          Text(
            filter == .unread
              ? "No unread articles in this category."
              : "No read articles in this category."
          )
        }
      }
    }
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
  @Query(filter: #Predicate<Category> { $0.isTopLevel == true }, sort: \Category.sortOrder)
  private var topLevelCategories: [Category]
  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]
  @State
  private var selectedEntry: Entry?
  @State
  private var selectedCategory: String?
  @State
  private var articleFilter: ArticleFilter = .unread
  @State
  private var articleViewMode: ArticleViewMode = .web
  @State
  private var needsSetup = false
  @State
  private var pendingReadIDs: Set<Int> = []
  private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
  private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
  private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some View {
    NavigationSplitView {
      sidebarView
    } content: {
      if let category = selectedCategory {
        EntryListView(category: category, filter: articleFilter, cutoffDate: syncEngine.queryCutoffDate, selectedEntry: $selectedEntry)
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
                Label("Mark All as Read", systemImage: "checkmark")
              }
              .disabled(articleFilter == .read)
              .help("Mark all as read (⇧A)")
              .accessibilityIdentifier("toolbar.markAllRead")
            }
          }
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: articleFilter)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedCategory)
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
    .onAppear {
      checkCredentials()
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
    }
    .onChange(of: articleFilter) {
      flushPendingReads()
      selectedEntry = nil
    }
    .onChange(of: selectedCategory) {
      flushPendingReads()
      selectedEntry = nil
    }
    .onChange(of: topLevelCategories.count) {
      if selectedCategory == nil, let first = topLevelCategories.first {
        selectedCategory = first.label
      }
    }
    .onChange(of: scenePhase) {
      if scenePhase != .active {
        flushPendingReads()
        Task { await syncEngine.pushPendingReads() }
      }
    }
    // Keyboard navigation
    .onKeyPress(.escape) {
      selectedEntry = nil
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in
      openInBackground()
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in
      guard selectedEntry != nil else { return .ignored }
      articleViewMode = articleViewMode == .web ? .reader : .web
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "A")) { _ in
      guard articleFilter == .unread, selectedCategory != nil else { return .ignored }
      markAllAsRead()
      return .handled
    }
  }

  // MARK: - Child lookup (small category count, acceptable in-memory filter)

  private func childCategories(of parentLabel: String) -> [Category] {
    allCategories
      .filter { $0.parentLabel == parentLabel }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  // MARK: - Actions

  private func flushPendingReads() {
    let ids = pendingReadIDs
    guard !ids.isEmpty else { return }
    pendingReadIDs.removeAll()
    syncEngine.queueReadIDs(ids)
    Task {
      guard let writer = syncEngine.writer else { return }
      for entryID in ids {
        try? await writer.markEntryRead(feedbinEntryID: entryID)
      }
    }
  }

  private func markAllAsRead() {
    guard let category = selectedCategory, let writer = syncEngine.writer else { return }
    selectedEntry = nil
    Task {
      let markedIDs = try await writer.markAllAsRead(
        category: category, cutoffDate: syncEngine.queryCutoffDate)
      if !markedIDs.isEmpty {
        syncEngine.queueReadIDs(markedIDs)
      }
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
    List(selection: $selectedCategory) {
      Section {
        ForEach(topLevelCategories) { parent in
          Text(parent.displayName)
            .font(.system(size: FontTheme.metadataSize))
            .tag(parent.label)
            .accessibilityIdentifier("sidebar.category.\(parent.label)")
          ForEach(childCategories(of: parent.label)) { child in
            Text(child.displayName)
              .font(.system(size: FontTheme.metadataSize))
              .padding(.leading, 16)
              .tag(child.label)
              .accessibilityIdentifier("sidebar.category.\(child.label)")
          }
        }
      } header: {
        SyncStatusView()
      }
    }
    .listStyle(.sidebar)
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
    if let category = selectedCategory,
      let cat = allCategories.first(where: { $0.label == category })
    {
      return cat.displayName
    }
    return "Articles"
  }

  // MARK: - Detail

  @ViewBuilder
  private var detailView: some View {
    if let selectedEntry {
      EntryDetailView(entry: selectedEntry, viewMode: articleViewMode)
        .toolbar {
          ToolbarItem(placement: .automatic) {
            Button {
              articleViewMode = articleViewMode == .web ? .reader : .web
            } label: {
              Label(
                articleViewMode == .web ? "Reader Mode" : "Web Mode",
                systemImage: articleViewMode == .web ? "doc.plaintext" : "doc.richtext"
              )
            }
            .help(articleViewMode == .web ? "Switch to reader mode (R)" : "Switch to web mode (R)")
          }
          ToolbarItem(placement: .automatic) {
            Button {
              openInBackground()
            } label: {
              Label("Open in Browser", systemImage: "safari")
            }
            .help("Open in browser (B)")
          }
        }
    } else {
      ContentUnavailableView {
        Label("Select an Article", systemImage: "doc.text")
      } description: {
        Text("Choose an article from the list to read it.")
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
      if selectedCategory == nil {
        selectedCategory = topLevelCategories.first?.label
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
        selectedCategory = "technology"
      }
    }
  }

  private func startSync() {
    let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
    let password = KeychainHelper.load(key: "feedbin_password") ?? ""
    guard !username.isEmpty, !password.isEmpty else { return }

    syncEngine.configure(username: username, password: password, modelContainer: modelContext.container)

    // Purge entries older than 30 days (max setting) — @Query date filter handles visibility
    Task {
      if let writer = syncEngine.writer {
        let cutoff = Date().addingTimeInterval(-maxRetentionAge)
        try? await writer.purgeEntriesOlderThan(cutoff)
      }
    }

    syncEngine.startPeriodicSync()
    if let writer = syncEngine.writer {
      classificationEngine.startContinuousClassification(writer: writer)
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
  guard let container = try? ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config) else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let technology = Category(
    label: "technology", displayName: "Technology", categoryDescription: "Technology coverage for preview", sortOrder: 0)
  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple preview", sortOrder: 0, parentLabel: "technology")
  let world = Category(label: "world_news", displayName: "World News", categoryDescription: "World coverage for preview", sortOrder: 1)
  context.insert(technology)
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
    entry.categoryLabels = ["technology"]
    entry.primaryCategory = "technology"
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
