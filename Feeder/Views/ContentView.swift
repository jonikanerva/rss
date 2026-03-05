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

    /// Entries filtered by selected category. Only shows classified entries.
    private var filteredEntries: [Entry] {
        guard let category = selectedCategory else { return [] }
        return entries.filter { $0.storyKey != nil && $0.categoryLabels.contains(category) }
    }

    /// Build timeline items: merge story groups and standalone entries, sorted newest-first.
    private var timelineItems: [TimelineItem] {
        let relevantEntries = filteredEntries

        // Collect storyKeys that have groups
        let groupedKeys = Set(storyGroups.map(\.storyKey))

        // Build group items — only include groups that have entries matching the current filter
        var items: [TimelineItem] = []
        for group in storyGroups {
            let groupEntries = relevantEntries.filter { $0.storyKey == group.storyKey }
            if groupEntries.count >= 2 {
                items.append(.group(group, groupEntries.sorted { $0.publishedAt > $1.publishedAt }))
            } else if groupEntries.count == 1 {
                items.append(.standalone(groupEntries[0]))
            }
        }

        // Add standalone entries (not part of any multi-entry group)
        let singleEntryGroupKeys = Set(
            storyGroups.map(\.storyKey).filter { key in
                relevantEntries.filter { $0.storyKey == key }.count < 2
            }
        )
        for entry in relevantEntries {
            let key = entry.storyKey ?? ""
            let isInMultiEntryGroup = groupedKeys.contains(key) && !key.isEmpty && !singleEntryGroupKeys.contains(key)
            let alreadyAddedAsSingle = singleEntryGroupKeys.contains(key)
            if !isInMultiEntryGroup && !alreadyAddedAsSingle {
                items.append(.standalone(entry))
            }
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

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebarView
            } content: {
                entryListView
            } detail: {
                detailView
            }

        }
        .frame(minWidth: 900, minHeight: 600)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("News")
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 4)

            // Status lines
            VStack(alignment: .leading, spacing: 2) {
                if isFetching {
                    Text("Fetching...")
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if classificationEngine.isClassifying {
                    let current = String(classificationEngine.classifiedCount)
                    let total = String(classificationEngine.totalToClassify)
                    Text("Classifying (\(current)/\(total))")
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if groupingEngine.isGrouping {
                    Text("Grouping...")
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !isFetching && !classificationEngine.isClassifying && !groupingEngine.isGrouping {
                    if let syncText = lastSyncText {
                        Text(syncText)
                            .transition(.opacity)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.3), value: isFetching)
            .animation(.easeInOut(duration: 0.3), value: classificationEngine.isClassifying)
            .animation(.easeInOut(duration: 0.3), value: groupingEngine.isGrouping)

            List {
                ForEach(categories) { category in
                    Button {
                        selectedCategory = category.label
                    } label: {
                        Text(category.displayName)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedCategory == category.label
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("")
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
            }
        }
    }

    // MARK: - Entry List (Timeline)

    @ViewBuilder
    private var entryListView: some View {
        let items = timelineItems
        Group {
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
            } else {
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
            }
        }
        .navigationTitle(navigationTitle)
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
        if selectedEntry != nil {
            EntryDetailView(selectedEntry: $selectedEntry)
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
        let username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
        let password = KeychainHelper.load(key: "feedbin_password") ?? ""
        if username.isEmpty || password.isEmpty {
            needsSetup = true
        } else {
            startSync()
        }
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
