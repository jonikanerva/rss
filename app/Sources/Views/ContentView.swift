import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Entry.publishedAt, order: .reverse) private var entries: [Entry]
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var selectedEntry: Entry?
    @State private var selectedCategory: String? // nil = all
    @State private var needsSetup = false
    @State private var showCategoryManagement = false

    /// Entries filtered by selected category.
    private var filteredEntries: [Entry] {
        guard let category = selectedCategory else { return entries }
        return entries.filter { $0.categoryLabels.contains(category) }
    }

    var body: some View {
        NavigationSplitView {
            sidebarView
        } content: {
            entryListView
        } detail: {
            detailView
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
            // Auto-classify after sync completes
            if wasSyncing && !isSyncing && !classificationEngine.isClassifying {
                Task {
                    await classificationEngine.classifyUnclassified(in: modelContext)
                }
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
                        Label("\(category.displayName) (\(count))", systemImage: "tag")
                            .tag(category.label as String?)
                    }
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
                    if syncEngine.isSyncing || classificationEngine.isClassifying {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(syncEngine.isSyncing || classificationEngine.isClassifying)
                .help("Sync and classify")
            }
        }
    }

    // MARK: - Entry List

    @ViewBuilder
    private var entryListView: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView {
                Label("No Articles", systemImage: "newspaper")
            } description: {
                if syncEngine.isSyncing {
                    Text(syncEngine.syncProgress)
                } else if classificationEngine.isClassifying {
                    Text(classificationEngine.progress)
                } else if let error = syncEngine.lastError {
                    Text(error)
                } else if selectedCategory != nil {
                    Text("No articles in this category.")
                } else {
                    Text("Sync with Feedbin to see your articles.")
                }
            }
        } else {
            List(filteredEntries, selection: $selectedEntry) { entry in
                EntryRowView(entry: entry)
                    .tag(entry)
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
    }
}
