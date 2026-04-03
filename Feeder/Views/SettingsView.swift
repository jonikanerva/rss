import SwiftData
import SwiftUI

struct SettingsView: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Query
  private var entries: [Entry]
  @Query
  private var categories: [Category]
  @State
  private var username = UserDefaults.standard.string(forKey: "feedbin_username") ?? ""
  @State
  private var password = KeychainHelper.load(key: "feedbin_password") ?? ""
  @State
  private var isSaving = false
  @State
  private var statusMessage: String?
  @State
  private var showAccountEditor = false
  @State
  private var syncInterval: Double = UserDefaults.standard.double(forKey: "sync_interval").clamped(to: 60...3600, default: 300)
  @State
  private var keepDays: Int = {
    let stored = UserDefaults.standard.integer(forKey: "article_keep_days")
    return stored > 0 ? stored : 7
  }()

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

      classificationTab
        .tabItem {
          Label("Classification", systemImage: "brain")
        }
    }
    .frame(
      minWidth: 420, idealWidth: 480, maxWidth: 550,
      minHeight: 450, idealHeight: 550, maxHeight: 700)
  }

  // MARK: - Account Tab

  private var accountTab: some View {
    Form {
      Section("Feedbin Account") {
        LabeledContent("Email") {
          Text(username.isEmpty ? "Not configured" : username)
            .foregroundStyle(username.isEmpty ? .tertiary : .secondary)
        }
        LabeledContent("Password") {
          Text(password.isEmpty ? "Not set" : "•••••")
            .foregroundStyle(password.isEmpty ? .tertiary : .secondary)
        }
        Button("Edit") {
          showAccountEditor = true
        }
        .accessibilityIdentifier("settings.account.edit")
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
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showAccountEditor) {
      AccountEditSheet(
        username: $username, password: $password,
        isSaving: $isSaving, statusMessage: $statusMessage,
        onSave: { Task { await save() } }
      )
    }
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

        Picker("Keep articles", selection: $keepDays) {
          Text("1 day").tag(1)
          Text("3 days").tag(3)
          Text("7 days").tag(7)
          Text("14 days").tag(14)
          Text("30 days").tag(30)
        }
        .onChange(of: keepDays) { oldValue, newValue in
          UserDefaults.standard.set(newValue, forKey: "article_keep_days")
          syncEngine.refreshArticleCutoff()
          if let writer = syncEngine.writer {
            classificationEngine.stopContinuousClassification()
            classificationEngine.startContinuousClassification(writer: writer)
          }
          if newValue > oldValue {
            syncEngine.refetchHistory()
          }
        }
      }

      Section("Status") {
        LabeledContent("Last sync") {
          if let date = syncEngine.lastSyncDate {
            Text(formatEntryDate(date))
              .foregroundStyle(.secondary)
          } else {
            Text("Never")
              .foregroundStyle(.tertiary)
          }
        }

        if let error = syncEngine.lastError {
          LabeledContent("Error") {
            Text(error)
              .foregroundStyle(.red)
              .font(FontTheme.caption)
          }
        }
      }

      Section {
        Button("Sync Now") {
          Task {
            await syncEngine.sync()
            if let writer = syncEngine.writer {
              await classificationEngine.classifyUnclassified(writer: writer)
            }
          }
        }
        .disabled(syncEngine.isSyncing || classificationEngine.isClassifying)
        .accessibilityIdentifier("settings.sync.now")
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Categories Tab (inline editor)

  private var categoriesTab: some View {
    CategoryManagementView()
      .environment(classificationEngine)
      .environment(syncEngine)
  }

  // MARK: - Classification Tab

  private var classificationTab: some View {
    ClassificationSettingsView()
      .environment(classificationEngine)
      .environment(syncEngine)
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

// MARK: - Account Edit Sheet

private struct AccountEditSheet: View {
  @Binding
  var username: String
  @Binding
  var password: String
  @Binding
  var isSaving: Bool
  @Binding
  var statusMessage: String?
  let onSave: () -> Void

  @Environment(\.dismiss)
  private var dismiss
  @State
  private var editUsername: String = ""
  @State
  private var editPassword: String = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Edit Account")
          .font(FontTheme.headline)
        Spacer()
      }
      .padding()
      Divider()

      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Email")
            .font(FontTheme.caption)
            .foregroundStyle(.secondary)
          TextField("Email", text: $editUsername)
            .textFieldStyle(.roundedBorder)
            .textContentType(.emailAddress)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("Password")
            .font(FontTheme.caption)
            .foregroundStyle(.secondary)
          SecureField("Password", text: $editPassword)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
        }

        if let status = statusMessage {
          Text(status)
            .foregroundStyle(status.contains("Error") ? .red : .green)
            .font(FontTheme.caption)
        }
      }
      .padding()

      Divider()
      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("Save") {
          username = editUsername
          password = editPassword
          onSave()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(editUsername.isEmpty || editPassword.isEmpty || isSaving)

        if isSaving {
          ProgressView()
            .scaleEffect(0.7)
        }
      }
      .padding()
    }
    .frame(width: 400)
    .onAppear {
      editUsername = username
      editPassword = password
    }
    .onChange(of: statusMessage) { _, newValue in
      if let msg = newValue, msg == "Saved" {
        dismiss()
      }
    }
  }
}

// MARK: - Helper extension

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
    if self == 0 { return defaultValue }
    return min(max(self, range.lowerBound), range.upperBound)
  }
}

// MARK: - Preview

#Preview("Settings - Seeded Data") {
  settingsSeededPreview()
}

#Preview("Account Edit Sheet") {
  AccountEditSheet(
    username: .constant("user@example.com"),
    password: .constant("secret123"),
    isSaving: .constant(false),
    statusMessage: .constant(nil),
    onSave: {}
  )
}

@MainActor
private func settingsSeededPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let feed = Feed(
    feedbinSubscriptionID: 1,
    feedbinFeedID: 1,
    title: "The Verge",
    feedURL: "https://theverge.com/rss",
    siteURL: "https://theverge.com",
    createdAt: .now
  )
  context.insert(feed)

  let technology = Category(label: "technology", displayName: "Technology", categoryDescription: "Technology news", sortOrder: 0)
  let apple = Category(label: "apple", displayName: "Apple", categoryDescription: "Apple news", sortOrder: 0, parentLabel: "technology")
  let world = Category(label: "world_news", displayName: "World News", categoryDescription: "World policy news", sortOrder: 1)
  context.insert(technology)
  context.insert(apple)
  context.insert(world)

  let entry = Entry(
    feedbinEntryID: 1,
    title: "Apple unveils M5 Ultra chip",
    author: "Tom Warren",
    url: "https://example.com/1",
    content: "<p>Apple announced a new chip architecture.</p>",
    summary: "Apple announced the M5 Ultra.",
    extractedContentURL: nil,
    publishedAt: .now.addingTimeInterval(-3600),
    createdAt: .now
  )
  entry.feed = feed
  entry.categoryLabels = ["apple"]
  entry.primaryCategory = "apple"
  entry.storyKey = "apple-m5-ultra"
  context.insert(entry)
  try? context.save()

  return SettingsView()
    .environment(SyncEngine())
    .environment(ClassificationEngine())
    .modelContainer(container)
}
