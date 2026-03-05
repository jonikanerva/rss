import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Environment(GroupingEngine.self) private var groupingEngine
    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [Entry]
    @Query private var categories: [Category]
    @Query private var storyGroups: [StoryGroup]
    @State private var username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
    @State private var password = KeychainHelper.load(key: "feedbin_password") ?? ""
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var syncInterval: Double = UserDefaults.standard.double(forKey: "sync_interval").clamped(to: 60...3600, default: 300)
    @State private var showCategoryManagement = false

    var body: some View {
        TabView {
            accountTab
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }

            syncTab
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            categoriesTab
                .tabItem {
                    Label("Categories", systemImage: "tag")
                }
        }
        .frame(width: 500, height: 380)
        .sheet(isPresented: $showCategoryManagement) {
            CategoryManagementView()
                .environment(classificationEngine)
                .frame(width: 550, height: 500)
        }
    }

    // MARK: - Account Tab

    private var accountTab: some View {
        Form {
            Section("Feedbin Account") {
                TextField("Email", text: $username)
                    .textContentType(.emailAddress)
                    .accessibilityLabel("Feedbin email address")

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityLabel("Feedbin password")

                HStack {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(username.isEmpty || password.isEmpty || isSaving)

                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    if let status = statusMessage {
                        Text(status)
                            .foregroundStyle(status.contains("Error") ? .red : .green)
                            .font(.caption)
                    }
                }
            }

            Section("Data") {
                LabeledContent("Articles") {
                    Text("\(entries.count)")
                        .monospacedDigit()
                }
                LabeledContent("Categories") {
                    Text("\(categories.count)")
                        .monospacedDigit()
                }
                LabeledContent("Story groups") {
                    Text("\(storyGroups.count)")
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sync Tab

    private var syncTab: some View {
        Form {
            Section("Sync Schedule") {
                Picker("Interval", selection: $syncInterval) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                }
                .onChange(of: syncInterval) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "sync_interval")
                }
            }

            Section("Status") {
                LabeledContent("Last sync") {
                    if let date = syncEngine.lastSyncDate {
                        Text(date, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never")
                            .foregroundStyle(.tertiary)
                    }
                }

                LabeledContent("Sync") {
                    Text(syncEngine.syncProgress)
                        .foregroundStyle(.secondary)
                }

                if classificationEngine.isClassifying {
                    LabeledContent("Classification") {
                        Text(classificationEngine.progress)
                            .foregroundStyle(.secondary)
                    }
                }

                if groupingEngine.isGrouping {
                    LabeledContent("Grouping") {
                        Text(groupingEngine.progress)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = syncEngine.lastError {
                    LabeledContent("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }

            Section {
                Button("Sync Now") {
                    Task {
                        await syncEngine.sync()
                        await classificationEngine.classifyUnclassified(in: modelContext)
                        await groupingEngine.groupEntries(in: modelContext)
                    }
                }
                .disabled(syncEngine.isSyncing || classificationEngine.isClassifying || groupingEngine.isGrouping)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Categories Tab

    private var categoriesTab: some View {
        Form {
            Section("Category Management") {
                Button("Open Category Editor") {
                    showCategoryManagement = true
                }
                .accessibilityLabel("Open category management window")

                Button("Reclassify All Articles") {
                    Task {
                        await classificationEngine.reclassifyAll(in: modelContext)
                        await groupingEngine.groupEntries(in: modelContext)
                    }
                }
                .disabled(categories.isEmpty || classificationEngine.isClassifying)
            }

            if classificationEngine.isClassifying {
                Section("Progress") {
                    ProgressView(value: Double(classificationEngine.classifiedCount), total: Double(classificationEngine.totalToClassify))
                    Text(classificationEngine.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Current Categories") {
                if categories.isEmpty {
                    Text("No categories defined. Open the category editor to add some.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(categories) { category in
                        LabeledContent(category.displayName) {
                            Text(category.label)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func save() async {
        isSaving = true
        statusMessage = nil

        let client = FeedbinClient(username: username, password: password)
        do {
            let valid = try await client.verifyCredentials()
            if valid {
                UserDefaults.standard.set(username, forKey: "feedbin_username")
                KeychainHelper.save(key: "feedbin_password", value: password)
                statusMessage = "Saved"
            } else {
                statusMessage = "Error: Invalid credentials"
            }
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        isSaving = false
    }
}

// MARK: - Helper extension

private extension Double {
    func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
        if self == 0 { return defaultValue }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
