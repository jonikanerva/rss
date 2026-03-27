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

// MARK: - Entry List View (dynamic @Query filtered by category + read status in SQLite)

struct EntryListView: View {
  @Query
  private var entries: [Entry]
  @Binding
  var selectedEntry: Entry?
  private let filter: ArticleFilter
  private let pendingReadIDs: Set<Int>

  init(category: String, filter: ArticleFilter, pendingReadIDs: Set<Int>, selectedEntry: Binding<Entry?>) {
    let showRead = filter == .read
    _entries = Query(
      filter: #Predicate<Entry> {
        $0.isClassified && $0.primaryCategory == category && $0.isRead == showRead
      },
      sort: \Entry.publishedAt,
      order: .reverse
    )
    self.filter = filter
    self.pendingReadIDs = pendingReadIDs
    _selectedEntry = selectedEntry
  }

  var body: some View {
    List(selection: $selectedEntry) {
      ForEach(entries) { entry in
        EntryRowView(entry: entry, visuallyRead: pendingReadIDs.contains(entry.feedbinEntryID))
          .tag(entry)
      }
    }
    .listStyle(.plain)
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
  private var needsSetup = false
  @State
  private var pendingReadIDs: Set<Int> = []
  private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
  private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
  private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }

  /// Formatted last sync time for display.
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
      let progress = syncEngine.syncProgress
      if !progress.isEmpty {
        return progress
      }
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
    NavigationSplitView {
      sidebarView
    } content: {
      if let category = selectedCategory {
        EntryListView(category: category, filter: articleFilter, pendingReadIDs: pendingReadIDs, selectedEntry: $selectedEntry)
          .safeAreaInset(edge: .top) {
            Picker("Filter", selection: $articleFilter) {
              ForEach(ArticleFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
          }
          .navigationTitle(navigationTitle)
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
      }
    }
    // Keyboard navigation
    .onKeyPress(.escape) {
      selectedEntry = nil
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "b")) { _ in
      openInBackground()
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
    Task {
      guard let writer = syncEngine.writer else { return }
      for entryID in ids {
        try? await writer.markEntryRead(feedbinEntryID: entryID)
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
          }
          if let classifyStatus = classifyStatusText {
            Text(classifyStatus)
              .font(.system(size: FontTheme.statusSize))
              .foregroundStyle(.tertiary)
              .textCase(nil)
          }
        }
        .padding(.bottom, 4)
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
      EntryDetailView(entry: selectedEntry)
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

    // Purge old entries via background DataWriter
    Task {
      if let writer = syncEngine.writer {
        let cutoff = Date().addingTimeInterval(-maxArticleAge)
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
  let world = Category(label: "world", displayName: "World", categoryDescription: "World coverage for preview", sortOrder: 1)
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
