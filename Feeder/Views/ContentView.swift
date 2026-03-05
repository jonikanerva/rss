import SwiftUI
import SwiftData

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
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \StoryGroup.earliestDate, order: .reverse) private var storyGroups: [StoryGroup]
    @State private var selectedEntry: Entry?
    @State private var selectedCategory: String? // nil = all
    @State private var needsSetup = false
    @State private var showCategoryManagement = false
    @State private var expandedGroups: Set<String> = []

    /// Entries filtered by selected category.
    private var filteredEntries: [Entry] {
        guard let category = selectedCategory else { return entries }
        return entries.filter { $0.categoryLabels.contains(category) }
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

    /// Whether any background operation is in progress.
    private var isWorking: Bool {
        syncEngine.isSyncing || syncEngine.isBackfilling || classificationEngine.isClassifying || groupingEngine.isGrouping
    }

    /// Current status message for the status bar.
    private var statusText: String? {
        if syncEngine.isSyncing { return syncEngine.syncProgress }
        if classificationEngine.isClassifying { return classificationEngine.progress }
        if groupingEngine.isGrouping { return groupingEngine.progress }
        if syncEngine.isBackfilling { return syncEngine.syncProgress }
        if let error = syncEngine.lastError { return error }
        return nil
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

            // Status bar
            if let status = statusText {
                HStack(spacing: 8) {
                    if isWorking {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: statusText != nil)
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
        .onChange(of: classificationEngine.isClassifying) { wasClassifying, isClassifying in
            if wasClassifying && !isClassifying && !groupingEngine.isGrouping {
                Task {
                    await groupingEngine.groupEntries(in: modelContext)
                }
            }
        }
        // Keyboard navigation
        .onKeyPress(.downArrow) { navigateEntry(direction: .next); return .handled }
        .onKeyPress(.upArrow) { navigateEntry(direction: .previous); return .handled }
        .onKeyPress(.return) { handleReturn(); return .handled }
        .onKeyPress(.escape) { selectedEntry = nil; return .handled }
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection { case next, previous }

    private func navigateEntry(direction: NavigationDirection) {
        let entries = selectableEntries
        guard !entries.isEmpty else { return }

        guard let current = selectedEntry,
              let index = entries.firstIndex(of: current) else {
            // Nothing selected — select first or last depending on direction
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
        // If an entry in a group is selected, ensure the group is expanded
        if let entry = selectedEntry, let key = entry.storyKey, !key.isEmpty {
            if storyGroups.contains(where: { $0.storyKey == key }) {
                expandedGroups.insert(key)
            }
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarView: some View {
        List(selection: $selectedCategory) {
            Section("Timeline") {
                Label("All (\(entries.count))", systemImage: "newspaper")
                    .tag(nil as String?)
            }

            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories) { category in
                        let count = entries.filter { $0.categoryLabels.contains(category.label) }.count
                        HStack {
                            Label(category.displayName, systemImage: "tag")
                            Spacer()
                            Text("\(count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .tag(category.label as String?)
                    }
                }
            }

            if !storyGroups.isEmpty {
                Section("Stories") {
                    HStack {
                        Label("Groups", systemImage: "rectangle.stack")
                        Spacer()
                        Text("\(storyGroups.count)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section("Feeds") {
                ForEach(feeds) { feed in
                    Label {
                        Text(feed.title)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Feeder")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showCategoryManagement = true
                } label: {
                    Image(systemName: "tag")
                }
                .help("Manage categories")

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
        if items.isEmpty {
            ContentUnavailableView {
                Label("No Articles", systemImage: "newspaper")
            } description: {
                if syncEngine.isSyncing {
                    Text(syncEngine.syncProgress)
                } else if classificationEngine.isClassifying {
                    Text(classificationEngine.progress)
                } else if groupingEngine.isGrouping {
                    Text(groupingEngine.progress)
                } else if let error = syncEngine.lastError {
                    Text(error)
                } else if selectedCategory != nil {
                    Text("No articles in this category.")
                } else {
                    Text("Sync with Feedbin to see your articles.")
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
            .navigationTitle(navigationTitle)
        }
    }

    private var navigationTitle: String {
        if let category = selectedCategory,
           let cat = categories.first(where: { $0.label == category }) {
            return cat.displayName
        }
        return "All Articles"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        if let entry = selectedEntry {
            EntryDetailView(entry: entry)
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
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            Text("\(entries.count) articles")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("·")
                                .foregroundStyle(.quaternary)

                            Text(group.earliestDate, style: .relative)
                                .font(.caption)
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
