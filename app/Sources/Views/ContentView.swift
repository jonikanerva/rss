import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Entry.publishedAt, order: .reverse) private var entries: [Entry]
    @Query(sort: \Feed.title) private var feeds: [Feed]
    @State private var selectedEntry: Entry?
    @State private var needsSetup = false

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
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarView: some View {
        List {
            Section("Feeds") {
                NavigationLink {
                    Text("All articles")
                } label: {
                    Label("All (\(entries.count))", systemImage: "newspaper")
                }

                ForEach(feeds) { feed in
                    NavigationLink {
                        Text(feed.title)
                    } label: {
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
        }
        .listStyle(.sidebar)
        .navigationTitle("Feeder")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await syncEngine.sync() }
                } label: {
                    if syncEngine.isSyncing {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(syncEngine.isSyncing)
                .help("Sync with Feedbin")
            }
        }
    }

    // MARK: - Entry List

    @ViewBuilder
    private var entryListView: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No Articles", systemImage: "newspaper")
            } description: {
                if syncEngine.isSyncing {
                    Text(syncEngine.syncProgress)
                } else if let error = syncEngine.lastError {
                    Text(error)
                } else {
                    Text("Sync with Feedbin to see your articles.")
                }
            }
        } else {
            List(entries, selection: $selectedEntry) { entry in
                EntryRowView(entry: entry)
                    .tag(entry)
            }
            .listStyle(.plain)
            .navigationTitle("Articles")
        }
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
}
