import SwiftData
import SwiftUI

// MARK: - Visible Entry IDs Preference Key

/// Bubbles the current entry IDs from EntryListView up to ContentView
/// so Tab can select the first article when switching to the article list.
/// Carries `PersistentIdentifier`s (Sendable, lightweight) — the Tab handler
/// materializes the first Entry on demand via `modelContext.model(for:)`.
struct VisibleEntryIDsKey: PreferenceKey {
  static let defaultValue: [PersistentIdentifier] = []
  static func reduce(value: inout [PersistentIdentifier], nextValue: () -> [PersistentIdentifier]) {
    value = nextValue()
  }
}

// MARK: - Entry List View (background-fetched section snapshots, no MainActor @Query)

/// Renders the article list for a given sidebar selection.
///
/// **Why not `@Query`**: SwiftData's `@Query` runs synchronously on MainActor
/// during view init/body. For large categories (e.g. "uncategorized" with
/// thousands of entries), the SQLite fetch + Entry materialization + day-grouping
/// blocks the main thread for seconds — even a `ProgressView` placeholder
/// can't paint because MainActor is busy.
///
/// Instead, the heavy fetch + grouping runs on `DataWriter` (a `@ModelActor`,
/// so on a background thread). The view holds lightweight `[EntryListSection]`
/// state (`PersistentIdentifier` arrays + section labels — Sendable DTOs) and
/// shows `ProgressView` instantly while the fetch runs. Each row materializes
/// its `Entry` lazily on MainActor via `modelContext.model(for:)` (cheap O(1)
/// primary-key lookup, only for visible rows).
///
/// **Live updates**: lost compared to `@Query` auto-refresh. Replaced by
/// explicit refresh-version triggers driven from `ContentView` — `.onChange`
/// handlers on `syncEngine.isSyncing` / `classificationEngine.isClassifying`
/// false-transitions, plus an explicit bump after `flushPendingReads` and
/// `markAllAsRead` writes.
struct EntryListView: View {
  let category: String?
  let folder: String?
  let filter: ArticleFilter
  let cutoffDate: Date
  let writer: DataWriter
  let refreshVersion: Int
  /// When non-nil, the row with this Feedbin entry ID is retained in the fetch
  /// result regardless of `isRead == showRead` — keeps a selected article
  /// visible after a cross-device sync flips its read state. The pin rides
  /// along with the next refresh trigger; selection changes alone do not
  /// re-fetch (avoids per-click background work).
  let pinnedFeedbinEntryID: Int?
  @Binding
  var selectedEntry: Entry?
  let onMarkAllRead: () -> Void

  @Environment(\.modelContext)
  private var modelContext
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(\.openSettings)
  private var openSettings
  /// Probe that fires while no entry has been classified yet. The static
  /// `FetchDescriptor` caps the fetch at one row regardless of inventory size,
  /// so the MainActor exception relative to this view's other reads (which
  /// run on `DataWriter`) stays inside the frame budget. Predicate pushed to
  /// SQLite — never filtered in Swift.
  ///
  /// Built lazily as a `static let` so the descriptor allocation happens once
  /// at module-init time rather than per view-init.
  private static let anyClassifiedProbeDescriptor: FetchDescriptor<Entry> = {
    var descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.isClassified == true }
    )
    descriptor.fetchLimit = 1
    return descriptor
  }()
  @Query(EntryListView.anyClassifiedProbeDescriptor)
  private var anyClassifiedProbe: [Entry]
  @State
  private var sections: [EntryListSection] = []
  /// Flattened entry IDs cached for the `VisibleEntryIDsKey` preference. Computed once
  /// per fetch (in `.task`) instead of `sections.flatMap(\.entryIDs)` on every body
  /// re-eval — meaningful for large categories ("uncategorized" with thousands of IDs).
  @State
  private var allVisibleEntryIDs: [PersistentIdentifier] = []
  @State
  private var hasLoaded = false

  // MARK: - Init
  //
  // Explicit init so Swift does not synthesize a memberwise init that exposes
  // the `@Query`-backed `anyClassifiedProbe` storage as a public parameter.
  // The synthesized form would require call sites to pass an `[Entry]` for the
  // probe; this init keeps the surface area identical to the pre-probe shape.
  init(
    category: String?,
    folder: String?,
    filter: ArticleFilter,
    cutoffDate: Date,
    writer: DataWriter,
    refreshVersion: Int,
    pinnedFeedbinEntryID: Int?,
    selectedEntry: Binding<Entry?>,
    onMarkAllRead: @escaping () -> Void
  ) {
    self.category = category
    self.folder = folder
    self.filter = filter
    self.cutoffDate = cutoffDate
    self.writer = writer
    self.refreshVersion = refreshVersion
    self.pinnedFeedbinEntryID = pinnedFeedbinEntryID
    self._selectedEntry = selectedEntry
    self.onMarkAllRead = onMarkAllRead
  }

  var body: some View {
    Group {
      if !hasLoaded {
        ProgressView()
          .controlSize(.regular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("timeline.loading")
      } else if sections.isEmpty {
        if case .authFailed = syncEngine.lastError {
          ContentUnavailableView {
            Label(
              "Signed out of Feedbin",
              systemImage: "person.crop.circle.badge.exclamationmark")
          } description: {
            Text("Sign in again to resume syncing your feeds.")
          } actions: {
            Button("Sign In Again") { openSettings() }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("timeline.authError.signIn")
          }
        } else if syncEngine.lastError?.isNetworkError == true {
          ContentUnavailableView(
            "Offline",
            systemImage: "wifi.slash",
            description: Text("Connect to the internet to sync new articles.")
          )
        } else if anyClassifiedProbe.isEmpty
          && (classificationEngine.isClassifying || syncEngine.isSyncing)
        {
          // First-sync / post-reset state: entries have landed but none are
          // classified yet, so this category-scoped fetch is empty while
          // classification catches up. Spinner-only (no SF Symbol) by
          // ux-guardian decision — the sidebar already carries progress
          // counts, so the middle pane stays calm and avoids double-signalling.
          // No trailing ellipsis on the headline per HIG: don't label a
          // spinning progress indicator.
          ContentUnavailableView {
            ProgressView()
              .controlSize(.large)
          } description: {
            VStack(spacing: 8) {
              Text("Sorting your articles")
                .font(.headline)
                .foregroundStyle(.primary)
              Text("We're placing fresh articles into your categories.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("timeline.firstSync")
        } else {
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
      } else {
        List(selection: $selectedEntry) {
          ForEach(sections) { section in
            Section {
              ForEach(section.entryIDs, id: \.self) { id in
                if let entry = modelContext.model(for: id) as? Entry {
                  EntryRowView(entry: entry)
                    .tag(entry)
                    .listRowSeparator(.hidden)
                }
              }
            } header: {
              Text(section.label)
                .font(fontSettings.sectionLabel)
                .foregroundStyle(.tertiary)
                .textCase(nil)
            }
          }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .modifier(BareKeyHandler())
        .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
        .preference(key: VisibleEntryIDsKey.self, value: allVisibleEntryIDs)
        .accessibilityIdentifier("timeline.list")
      }
    }
    // Two tasks so refresh-only ticks (classification / sync completion) do
    // not flip `hasLoaded` back to false and tear down the `List` — which
    // would reset scroll every time. `structuralKey` captures inputs whose
    // change means "user is looking at a different list" (category / folder
    // / filter / cutoff); only those warrant a loading view. `refreshVersion`
    // fires in place and `reload()` skips the assign when sections are
    // equal, so SwiftUI's diff keeps the scroll stable.
    //
    // The refresh task's id intentionally includes `structuralKey`: a bare
    // `refreshVersion` id would not be cancelled when the user switches
    // category mid-refresh, and the in-flight fetch — which captured `self`
    // with the old category — could race the structural task and overwrite
    // `sections` with stale rows from the previous list. Including
    // `structuralKey` cancels the stale refresh when context changes, and
    // the `guard hasLoaded` check keeps the restarted refresh a no-op while
    // the structural task owns the reload.
    .task(id: structuralKey) {
      hasLoaded = false
      await reload()
      hasLoaded = true
    }
    .task(id: refreshTaskKey) {
      guard hasLoaded else { return }
      await reload()
    }
  }

  private func reload() async {
    let result =
      (try? await writer.fetchEntrySections(
        category: category, folder: folder, showRead: filter == .read,
        cutoffDate: cutoffDate, pinnedFeedbinEntryID: pinnedFeedbinEntryID
      )) ?? []
    guard !Task.isCancelled else { return }
    if result != sections {
      sections = result
      allVisibleEntryIDs = result.flatMap(\.entryIDs)
    }
  }

  /// Composed key for the refresh task so a structural change (category /
  /// folder / filter / cutoff) cancels any in-flight refresh bound to the
  /// previous context. Without the structural suffix, a refresh captured
  /// against the old `self` could finish after the structural reload and
  /// overwrite `sections` with stale rows.
  private var refreshTaskKey: String {
    "\(structuralKey)|\(refreshVersion)"
  }

  /// Key for "this is a different article list" — user-visible context change.
  /// Excludes `refreshVersion`, which rides on a separate task so in-place
  /// refreshes do not tear down the `List` and drop the scroll position.
  private var structuralKey: String {
    "\(category ?? "")|\(folder ?? "")|\(filter.rawValue)|\(cutoffDate.timeIntervalSince1970)"
  }
}

// MARK: - Previews

#Preview("Empty - Offline") {
  EntryListOfflinePreview()
}

#Preview("Empty - Auth Failed") {
  EntryListAuthFailedPreview()
}

#Preview("Empty - First Sync") {
  EntryListFirstSyncPreview()
}

/// Renders `EntryListView` in the offline-empty state: container is seeded
/// but contains no entries, and `SyncEngine.lastError` is set to `.network`
/// so the view picks the `ContentUnavailableView("Offline", …)` branch.
@MainActor
private struct EntryListOfflinePreview: View {
  @State
  private var writer: DataWriter?
  @State
  private var selectedEntry: Entry?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine: SyncEngine = {
    let engine = SyncEngine()
    engine.applyPreviewState(
      lastError: .network("The Internet connection appears to be offline."))
    return engine
  }()
  private let classificationEngine = ClassificationEngine()

  var body: some View {
    Group {
      if let writer {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          writer: writer,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntry: $selectedEntry,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .task {
      writer = await DataWriter.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the auth-failed empty state: container is seeded
/// but contains no entries, and `SyncEngine.lastError` is set to `.authFailed`
/// so the view picks the "Signed out of Feedbin" branch.
@MainActor
private struct EntryListAuthFailedPreview: View {
  @State
  private var writer: DataWriter?
  @State
  private var selectedEntry: Entry?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine: SyncEngine = {
    let engine = SyncEngine()
    engine.applyPreviewState(
      lastError: .authFailed("Invalid Feedbin credentials"))
    return engine
  }()
  private let classificationEngine = ClassificationEngine()

  var body: some View {
    Group {
      if let writer {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          writer: writer,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntry: $selectedEntry,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .task {
      writer = await DataWriter.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the first-sync empty state: container is seeded
/// but contains no classified entries, `SyncEngine.lastError` is nil and
/// `ClassificationEngine` is mid-batch — so the view picks the "Sorting your
/// articles" branch.
@MainActor
private struct EntryListFirstSyncPreview: View {
  @State
  private var writer: DataWriter?
  @State
  private var selectedEntry: Entry?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine = SyncEngine()
  private let classificationEngine: ClassificationEngine = {
    let engine = ClassificationEngine()
    engine.applyPreviewState(
      isClassifying: true,
      progress: "Categorizing 12/47",
      classifiedCount: 12,
      totalToClassify: 47
    )
    return engine
  }()

  var body: some View {
    Group {
      if let writer {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          writer: writer,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntry: $selectedEntry,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .task {
      writer = await DataWriter.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}
