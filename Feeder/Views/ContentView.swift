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

// MARK: - Timeline item model

/// Represents either a standalone entry or a story group in the timeline.
enum TimelineItem: Identifiable {
    case standalone(Entry)
    case group(StoryGroup, [Entry])

    var id: String {
        switch self {
        case .standalone(let entry):
            return "entry-\(entry.feedbinEntryID)"
        case .group(let group, _):
            return "group-\(group.storyKey)"
        }
    }

    /// Sort date: entry publishedAt or group earliestDate.
    var sortDate: Date {
        switch self {
        case .standalone(let entry):
            return entry.publishedAt
        case .group(let group, _):
            return group.earliestDate
        }
    }

    /// All selectable entries from this timeline item (for keyboard nav).
    var selectableEntries: [Entry] {
        switch self {
        case .standalone(let entry):
            return [entry]
        case .group(_, let entries):
            return entries
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Environment(GroupingEngine.self) private var groupingEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Entry.publishedAt, order: .reverse) private var entries: [Entry]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \StoryGroup.earliestDate, order: .reverse) private var storyGroups: [StoryGroup]
    @State private var selectedEntry: Entry?
    @State private var selectedCategory: String? // nil = all
    @State private var needsSetup = false
    @State private var showCategoryManagement = false
    @State private var expandedGroups: Set<String> = []
    @State private var markReadTask: Task<Void, Never>?
    private var processEnvironment: [String: String] { ProcessInfo.processInfo.environment }
    private var isPreviewMode: Bool { processEnvironment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" }
    private var isUITestDemoMode: Bool { processEnvironment["UITEST_DEMO_MODE"] == "1" }
    private var isUITestForceOnboarding: Bool { processEnvironment["UITEST_FORCE_ONBOARDING"] == "1" }

    /// Entries filtered by selected category. Only shows classified entries.
    private var filteredEntries: [Entry] {
        guard let category = selectedCategory else { return [] }
        return entries.filter { $0.storyKey != nil && $0.categoryLabels.contains(category) }
    }

    /// Build timeline items: merge story groups and standalone entries, sorted newest-first.
    private var timelineItems: [TimelineItem] {
        let relevantEntries = filteredEntries

        // Index entries by storyKey for O(1) lookup instead of O(n) filtering per group
        var entriesByKey: [String: [Entry]] = [:]
        var ungroupedEntries: [Entry] = []
        let groupedKeys = Set(storyGroups.map(\.storyKey))

        for entry in relevantEntries {
            if let key = entry.storyKey, !key.isEmpty, groupedKeys.contains(key) {
                entriesByKey[key, default: []].append(entry)
            } else {
                ungroupedEntries.append(entry)
            }
        }

        var items: [TimelineItem] = []

        // Build group items
        for group in storyGroups {
            guard let groupEntries = entriesByKey[group.storyKey] else { continue }
            if groupEntries.count >= 2 {
                items.append(.group(group, groupEntries.sorted { $0.publishedAt > $1.publishedAt }))
            } else if groupEntries.count == 1 {
                items.append(.standalone(groupEntries[0]))
            }
        }

        // Add standalone entries (not part of any story group)
        for entry in ungroupedEntries {
            items.append(.standalone(entry))
        }

        return items.sorted { $0.sortDate > $1.sortDate }
    }

    /// Flat list of all selectable entries in timeline order (for keyboard navigation).
    private var selectableEntries: [Entry] {
        timelineItems.flatMap(\.selectableEntries)
    }

    /// Whether fetching is in progress (sync, backfill, or content fetch).
    private var isFetching: Bool {
        syncEngine.isSyncing || syncEngine.isBackfilling || syncEngine.isFetchingContent
    }

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

    private var statusText: String {
        if isFetching { return "Fetching..." }
        if classificationEngine.isClassifying {
            return "Classifying (\(classificationEngine.classifiedCount)/\(classificationEngine.totalToClassify))"
        }
        if groupingEngine.isGrouping { return "Grouping..." }
        return lastSyncText ?? ""
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
        } content: {
            entryListView
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
                .frame(width: 550, height: 500)
        }
        .onChange(of: syncEngine.isSyncing) { wasSyncing, isSyncing in
            if wasSyncing && !isSyncing && !classificationEngine.isClassifying {
                Task {
                    await classificationEngine.classifyUnclassified(in: modelContext)
                }
            }
        }
        .onChange(of: syncEngine.isBackfilling) { wasBackfilling, isBackfilling in
            if wasBackfilling && !isBackfilling && !classificationEngine.isClassifying {
                Task {
                    await classificationEngine.classifyUnclassified(in: modelContext)
                }
            }
        }
        .onChange(of: syncEngine.isFetchingContent) { wasFetching, isFetching in
            if wasFetching && !isFetching && !classificationEngine.isClassifying {
                Task {
                    await classificationEngine.classifyUnclassified(in: modelContext)
                }
            }
        }
        .onChange(of: classificationEngine.isClassifying) { wasClassifying, isClassifying in
            if wasClassifying && !isClassifying && !groupingEngine.isGrouping {
                Task {
                    await groupingEngine.groupEntries(in: modelContext)
                }
            }
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
        .onKeyPress(.return) { handleReturn(); return .handled }
        .onKeyPress(.escape) { selectedEntry = nil; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "b")) { _ in openInBackground(); return .handled }
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection { case next, previous }

    private func navigateEntry(direction: NavigationDirection) {
        let entries = selectableEntries
        guard !entries.isEmpty else { return }

        guard let current = selectedEntry,
              let index = entries.firstIndex(of: current) else {
            selectedEntry = direction == .next ? entries.first : entries.last
            return
        }

        switch direction {
        case .next:
            if index + 1 < entries.count {
                selectedEntry = entries[index + 1]
            }
        case .previous:
            if index > 0 {
                selectedEntry = entries[index - 1]
            }
        }
    }

    private func handleReturn() {
        if let entry = selectedEntry, let key = entry.storyKey, !key.isEmpty {
            if storyGroups.contains(where: { $0.storyKey == key }) {
                expandedGroups.insert(key)
            }
        }
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("News")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)

                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .textCase(nil)
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
                    if syncEngine.isSyncing || syncEngine.isBackfilling || classificationEngine.isClassifying || groupingEngine.isGrouping {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(syncEngine.isSyncing || syncEngine.isBackfilling || classificationEngine.isClassifying || groupingEngine.isGrouping)
                .help("Sync, classify, and group")
                .accessibilityIdentifier("toolbar.sync")
            }
        }
    }

    // MARK: - Entry List (Timeline)

    @ViewBuilder
    private var entryListView: some View {
        let items = timelineItems
        List(selection: $selectedEntry) {
            ForEach(items) { item in
                switch item {
                case .standalone(let entry):
                    EntryRowView(entry: entry)
                        .tag(entry)

                case .group(let group, let groupEntries):
                    StoryGroupRowView(
                        group: group,
                        entries: groupEntries,
                        isExpanded: expandedGroups.contains(group.storyKey),
                        selectedEntry: $selectedEntry,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expandedGroups.contains(group.storyKey) {
                                    expandedGroups.remove(group.storyKey)
                                } else {
                                    expandedGroups.insert(group.storyKey)
                                }
                            }
                        }
                    )
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("timeline.list")
        .navigationTitle(navigationTitle)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No Articles", systemImage: "newspaper")
                } description: {
                    if selectedCategory == nil {
                        Text("Select a category from the sidebar.")
                    } else {
                        Text("No classified articles in this category yet.")
                    }
                }
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

    /// Sibling entries for the selected entry (same storyKey, different sources).
    private var siblingEntries: [Entry] {
        guard let entry = selectedEntry,
              let key = entry.storyKey, !key.isEmpty else { return [] }
        return entries.filter { $0.storyKey == key }
    }

    @ViewBuilder
    private var detailView: some View {
        if let selectedEntry {
            EntryDetailView(entry: selectedEntry, siblings: siblingEntries)
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

        let technology = Category(
            label: "technology",
            displayName: "Technology",
            categoryDescription: "Technology coverage for local UI testing",
            sortOrder: 0
        )
        let world = Category(
            label: "world",
            displayName: "World",
            categoryDescription: "World news coverage for local UI testing",
            sortOrder: 1
        )
        modelContext.insert(technology)
        modelContext.insert(world)

        let feed1 = Feed(
            feedbinSubscriptionID: 1,
            feedbinFeedID: 1,
            title: "The Verge",
            feedURL: "https://theverge.com/rss",
            siteURL: "https://theverge.com",
            createdAt: .now
        )
        let feed2 = Feed(
            feedbinSubscriptionID: 2,
            feedbinFeedID: 2,
            title: "Ars Technica",
            feedURL: "https://arstechnica.com/rss",
            siteURL: "https://arstechnica.com",
            createdAt: .now
        )
        modelContext.insert(feed1)
        modelContext.insert(feed2)

        let story1 = Entry(
            feedbinEntryID: 1001,
            title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
            author: "Tom Warren",
            url: "https://example.com/story/1001",
            content: "<p>Apple announced a new chip architecture.</p>",
            summary: "Apple announced the M5 Ultra.",
            extractedContentURL: nil,
            publishedAt: .now.addingTimeInterval(-1800),
            createdAt: .now.addingTimeInterval(-1700)
        )
        story1.feed = feed1
        story1.categoryLabels = ["technology", "apple"]
        story1.storyKey = "apple-m5-ultra"
        story1.isRead = false
        modelContext.insert(story1)

        let story2 = Entry(
            feedbinEntryID: 1002,
            title: "Ars breakdown: what Apple's M5 Ultra means for laptops",
            author: "Andrew Cunningham",
            url: "https://example.com/story/1002",
            content: "<p>Analysis of M5 Ultra performance and efficiency.</p>",
            summary: "A deep dive into Apple's M5 Ultra.",
            extractedContentURL: nil,
            publishedAt: .now.addingTimeInterval(-1600),
            createdAt: .now.addingTimeInterval(-1500)
        )
        story2.feed = feed2
        story2.categoryLabels = ["technology", "apple"]
        story2.storyKey = "apple-m5-ultra"
        story2.isRead = true
        modelContext.insert(story2)

        for index in 3...14 {
            let entry = Entry(
                feedbinEntryID: 1000 + index,
                title: "Sample Tech Story \(index)",
                author: "Feeder Bot",
                url: "https://example.com/story/\(1000 + index)",
                content: "<p>Sample article \(index) for local UX smoke testing and scrolling behavior.</p>",
                summary: "Sample article \(index)",
                extractedContentURL: nil,
                publishedAt: .now.addingTimeInterval(-Double(index) * 900),
                createdAt: .now.addingTimeInterval(-Double(index) * 850)
            )
            entry.feed = index.isMultiple(of: 2) ? feed1 : feed2
            entry.categoryLabels = ["technology"]
            entry.storyKey = "sample-tech-story-\(index)"
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
        worldEntry.storyKey = "eu-ai-transparency-framework"
        worldEntry.isRead = false
        modelContext.insert(worldEntry)

        let group = StoryGroup(
            storyKey: "apple-m5-ultra",
            headline: "Apple unveils M5 Ultra chip",
            earliestDate: min(story1.publishedAt, story2.publishedAt)
        )
        group.entryCount = 2
        modelContext.insert(group)

        try? modelContext.save()
        selectedCategory = technology.label
        selectedEntry = story1
    }

    private func startSync() {
        let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
        let password = KeychainHelper.load(key: "feedbin_password") ?? ""
        guard !username.isEmpty, !password.isEmpty else { return }
        syncEngine.configure(username: username, password: password, modelContext: modelContext)
        syncEngine.startPeriodicSync()
    }

    private func syncAndClassify() async {
        await syncEngine.sync()
        await classificationEngine.classifyUnclassified(in: modelContext)
        await groupingEngine.groupEntries(in: modelContext)
    }
}

// MARK: - Story Group Row View

struct StoryGroupRowView: View {
    let group: StoryGroup
    let entries: [Entry]
    let isExpanded: Bool
    @Binding var selectedEntry: Entry?
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.headline)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            Text("\(entries.count) articles")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Text("·")
                                .foregroundStyle(.quaternary)

                            Text(group.earliestDate, style: .relative)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("story-group.toggle.\(group.storyKey)")

            // Expanded entries
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        EntryRowView(entry: entry)
                            .padding(.leading, 20)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedEntry = entry
                            }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Story group: \(group.headline), \(entries.count) articles")
        .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }
}

// MARK: - Preview

#Preview("Timeline - Seeded Demo") {
    timelineSeededDemoPreview()
}

@MainActor
private func timelineSeededDemoPreview() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Entry.self,
        Feed.self,
        Category.self,
        StoryGroup.self,
        configurations: config
    )
    let context = container.mainContext

    let technology = Category(
        label: "technology",
        displayName: "Technology",
        categoryDescription: "Technology coverage for preview",
        sortOrder: 0
    )
    let world = Category(
        label: "world",
        displayName: "World",
        categoryDescription: "World coverage for preview",
        sortOrder: 1
    )
    context.insert(technology)
    context.insert(world)

    let feed1 = Feed(
        feedbinSubscriptionID: 1,
        feedbinFeedID: 1,
        title: "The Verge",
        feedURL: "https://theverge.com/rss",
        siteURL: "https://theverge.com",
        createdAt: .now
    )
    let feed2 = Feed(
        feedbinSubscriptionID: 2,
        feedbinFeedID: 2,
        title: "Ars Technica",
        feedURL: "https://arstechnica.com/rss",
        siteURL: "https://arstechnica.com",
        createdAt: .now
    )
    context.insert(feed1)
    context.insert(feed2)

    let story1 = Entry(
        feedbinEntryID: 1,
        title: "Apple unveils M5 Ultra chip with record-breaking AI performance",
        author: "Tom Warren",
        url: "https://example.com/1",
        content: "<p>Apple announced a new chip architecture.</p>",
        summary: "Apple announced the M5 Ultra.",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-1800),
        createdAt: .now.addingTimeInterval(-1700)
    )
    story1.feed = feed1
    story1.categoryLabels = ["technology", "apple"]
    story1.storyKey = "apple-m5-ultra"
    context.insert(story1)

    let story2 = Entry(
        feedbinEntryID: 2,
        title: "Ars breakdown: what Apple's M5 Ultra means for laptops",
        author: "Andrew Cunningham",
        url: "https://example.com/2",
        content: "<p>Analysis of M5 Ultra performance and efficiency.</p>",
        summary: "A deep dive into Apple's M5 Ultra.",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-1600),
        createdAt: .now.addingTimeInterval(-1500)
    )
    story2.feed = feed2
    story2.categoryLabels = ["technology", "apple"]
    story2.storyKey = "apple-m5-ultra"
    context.insert(story2)

    let sample3 = Entry(
        feedbinEntryID: 3,
        title: "Sample Tech Story 3",
        author: "Feeder Bot",
        url: "https://example.com/3",
        content: "<p>Sample article 3 for preview and scroll behavior.</p>",
        summary: "Sample article 3",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-2700),
        createdAt: .now.addingTimeInterval(-2600)
    )
    sample3.feed = feed1
    sample3.categoryLabels = ["technology"]
    sample3.storyKey = "sample-tech-story-3"
    context.insert(sample3)

    let sample4 = Entry(
        feedbinEntryID: 4,
        title: "Sample Tech Story 4",
        author: "Feeder Bot",
        url: "https://example.com/4",
        content: "<p>Sample article 4 for preview and scroll behavior.</p>",
        summary: "Sample article 4",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-3600),
        createdAt: .now.addingTimeInterval(-3500)
    )
    sample4.feed = feed2
    sample4.categoryLabels = ["technology"]
    sample4.storyKey = "sample-tech-story-4"
    context.insert(sample4)

    let sample5 = Entry(
        feedbinEntryID: 5,
        title: "Sample Tech Story 5",
        author: "Feeder Bot",
        url: "https://example.com/5",
        content: "<p>Sample article 5 for preview and scroll behavior.</p>",
        summary: "Sample article 5",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-4500),
        createdAt: .now.addingTimeInterval(-4400)
    )
    sample5.feed = feed1
    sample5.categoryLabels = ["technology"]
    sample5.storyKey = "sample-tech-story-5"
    context.insert(sample5)

    let sample6 = Entry(
        feedbinEntryID: 6,
        title: "Sample Tech Story 6",
        author: "Feeder Bot",
        url: "https://example.com/6",
        content: "<p>Sample article 6 for preview and scroll behavior.</p>",
        summary: "Sample article 6",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-5400),
        createdAt: .now.addingTimeInterval(-5300)
    )
    sample6.feed = feed2
    sample6.categoryLabels = ["technology"]
    sample6.storyKey = "sample-tech-story-6"
    context.insert(sample6)

    let worldEntry = Entry(
        feedbinEntryID: 30,
        title: "EU passes major AI transparency framework",
        author: "Policy Desk",
        url: "https://example.com/30",
        content: "<p>European lawmakers finalized a new AI framework.</p>",
        summary: "EU finalizes AI transparency framework.",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-7200),
        createdAt: .now.addingTimeInterval(-7100)
    )
    worldEntry.feed = feed1
    worldEntry.categoryLabels = ["world", "technology"]
    worldEntry.storyKey = "eu-ai-transparency-framework"
    context.insert(worldEntry)

    let group = StoryGroup(
        storyKey: "apple-m5-ultra",
        headline: "Apple unveils M5 Ultra chip",
        earliestDate: min(story1.publishedAt, story2.publishedAt)
    )
    group.entryCount = 2
    context.insert(group)
    try? context.save()

    return ContentView()
        .environment(SyncEngine())
        .environment(ClassificationEngine())
        .environment(GroupingEngine())
        .modelContainer(container)
        .frame(minWidth: 1200, minHeight: 760)
}
