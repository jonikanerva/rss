import Foundation
import SwiftUI
import SwiftData

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

// MARK: - Entry List View (dynamic @Query filtered by category in SQLite)

struct EntryListView: View {
    @Query private var entries: [Entry]
    @Binding var selectedEntry: Entry?

    init(category: String, selectedEntry: Binding<Entry?>) {
        _entries = Query(
            filter: #Predicate<Entry> { $0.isClassified && $0.primaryCategory == category },
            sort: \Entry.publishedAt,
            order: .reverse
        )
        _selectedEntry = selectedEntry
    }

    var body: some View {
        List(selection: $selectedEntry) {
            ForEach(entries) { entry in
                EntryRowView(entry: entry)
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
                    Text("No classified articles in this category yet.")
                }
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var selectedEntry: Entry?
    @State private var selectedCategory: String? // nil = all
    @State private var needsSetup = false
    @State private var showCategoryManagement = false
    @State private var markReadTask: Task<Void, Never>?
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
            let n = syncEngine.fetchedCount
            let x = syncEngine.totalToFetch
            return x > 0 ? "Fetching \(n)/\(x)" : "Fetching..."
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
                EntryListView(category: category, selectedEntry: $selectedEntry)
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
        .sheet(isPresented: $showCategoryManagement) {
            CategoryManagementView()
                .environment(classificationEngine)
                .environment(syncEngine)
                .frame(width: 550, height: 500)
        }
        .onChange(of: selectedEntry) { _, newEntry in
            markReadTask?.cancel()
            if let entry = newEntry, !entry.isRead {
                markReadTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled {
                        entry.isRead = true
                    }
                }
            }
        }
        .onChange(of: categories.count) {
            if selectedCategory == nil, let first = categories.first {
                selectedCategory = first.label
            }
        }
        // Keyboard navigation
        .onKeyPress(.downArrow) { navigateEntry(direction: .next); return .handled }
        .onKeyPress(.upArrow) { navigateEntry(direction: .previous); return .handled }
        .onKeyPress(.escape) { selectedEntry = nil; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "b")) { _ in openInBackground(); return .handled }
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection { case next, previous }

    private func navigateEntry(direction: NavigationDirection) {
        // Keyboard nav needs the current list — but we can't access EntryListView's @Query from here.
        // For now this is a no-op when no entry is selected; arrow keys work via List's built-in selection.
        // TODO: Re-evaluate if custom keyboard nav is needed beyond List's default behavior.
    }

    private func openInBackground() {
        guard let entry = selectedEntry, let url = URL(string: entry.url) else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: NSWorkspace.shared.urlForApplication(toOpen: url)!,
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
                ForEach(categories) { category in
                    Text(category.displayName)
                        .tag(category.label)
                        .accessibilityIdentifier("sidebar.category.\(category.label)")
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("News")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)

                    if let fetchStatus = fetchStatusText {
                        Text(fetchStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .textCase(nil)
                    }
                    if let classifyStatus = classifyStatusText {
                        Text(classifyStatus)
                            .font(.system(size: 11))
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
                    if syncEngine.isSyncing || syncEngine.isBackfilling || classificationEngine.isClassifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(syncEngine.isSyncing || syncEngine.isBackfilling || classificationEngine.isClassifying)
                .help("Sync and classify")
                .accessibilityIdentifier("toolbar.sync")
            }
        }
    }

    private var navigationTitle: String {
        if let category = selectedCategory,
           let cat = categories.first(where: { $0.label == category }) {
            return cat.displayName
        }
        return "Articles"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let selectedEntry {
            EntryDetailView(entry: selectedEntry, siblings: [])
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
                selectedCategory = categories.first?.label
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
        let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Entry>())) ?? 0
        guard existingCount == 0 else { return }

        let technology = Category(label: "technology", displayName: "Technology", categoryDescription: "Technology coverage for local UI testing", sortOrder: 0)
        let world = Category(label: "world", displayName: "World", categoryDescription: "World news coverage for local UI testing", sortOrder: 1)
        modelContext.insert(technology)
        modelContext.insert(world)

        let feed1 = Feed(feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "The Verge", feedURL: "https://theverge.com/rss", siteURL: "https://theverge.com", createdAt: .now)
        let feed2 = Feed(feedbinSubscriptionID: 2, feedbinFeedID: 2, title: "Ars Technica", feedURL: "https://arstechnica.com/rss", siteURL: "https://arstechnica.com", createdAt: .now)
        modelContext.insert(feed1)
        modelContext.insert(feed2)

        for index in 1...12 {
            let entry = Entry(
                feedbinEntryID: 1000 + index,
                title: "Sample Tech Story \(index)",
                author: "Feeder Bot",
                url: "https://example.com/story/\(1000 + index)",
                content: "<p>Sample article \(index) for local UX smoke testing.</p>",
                summary: "Sample article \(index)",
                extractedContentURL: nil,
                publishedAt: .now.addingTimeInterval(-Double(index) * 900),
                createdAt: .now.addingTimeInterval(-Double(index) * 850)
            )
            entry.feed = index.isMultiple(of: 2) ? feed1 : feed2
            entry.categoryLabels = ["technology"]
            entry.primaryCategory = "technology"
            entry.storyKey = "sample-tech-story-\(index)"
            entry.isClassified = true
            entry.formattedDate = formatEntryDate(entry.publishedAt)
            entry.plainText = "Sample article \(index) for local UX smoke testing."
            entry.isRead = index.isMultiple(of: 3)
            modelContext.insert(entry)
        }

        let worldEntry = Entry(
            feedbinEntryID: 2001,
            title: "EU passes major AI transparency framework",
            author: "Policy Desk",
            url: "https://example.com/story/2001",
            content: "<p>European lawmakers finalized a new AI framework.</p>",
            summary: "EU finalizes AI transparency framework.",
            extractedContentURL: nil,
            publishedAt: .now.addingTimeInterval(-7200),
            createdAt: .now.addingTimeInterval(-7100)
        )
        worldEntry.feed = feed1
        worldEntry.categoryLabels = ["world", "technology"]
        worldEntry.primaryCategory = "world"
        worldEntry.storyKey = "eu-ai-transparency-framework"
        worldEntry.isClassified = true
        worldEntry.formattedDate = formatEntryDate(worldEntry.publishedAt)
        worldEntry.plainText = "European lawmakers finalized a new AI framework."
        worldEntry.isRead = false
        modelContext.insert(worldEntry)

        try? modelContext.save()
        selectedCategory = technology.label
    }

    private func startSync() {
        let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
        let password = KeychainHelper.load(key: "feedbin_password") ?? ""
        guard !username.isEmpty, !password.isEmpty else { return }

        syncEngine.configure(username: username, password: password, modelContainer: modelContext.container)

        // Purge old entries via background DataWriter
        Task {
            if let writer = syncEngine.writer {
                let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
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
    let container = try! ModelContainer(for: Entry.self, Feed.self, Category.self, configurations: config)
    let context = container.mainContext

    let technology = Category(label: "technology", displayName: "Technology", categoryDescription: "Technology coverage for preview", sortOrder: 0)
    let world = Category(label: "world", displayName: "World", categoryDescription: "World coverage for preview", sortOrder: 1)
    context.insert(technology)
    context.insert(world)

    let feed1 = Feed(feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "The Verge", feedURL: "https://theverge.com/rss", siteURL: "https://theverge.com", createdAt: .now)
    context.insert(feed1)

    for i in 1...5 {
        let entry = Entry(feedbinEntryID: i, title: "Sample Tech Story \(i)", author: "Feeder Bot", url: "https://example.com/\(i)", content: "<p>Sample article \(i).</p>", summary: "Sample \(i)", extractedContentURL: nil, publishedAt: .now.addingTimeInterval(-Double(i) * 900), createdAt: .now.addingTimeInterval(-Double(i) * 850))
        entry.feed = feed1
        entry.categoryLabels = ["technology"]
        entry.primaryCategory = "technology"
        entry.isClassified = true
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
