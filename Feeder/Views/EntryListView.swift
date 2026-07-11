import SwiftData
import SwiftUI
import os.signpost

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
  let reader: DataReader
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
  @State
  private var sections: [EntryListSection] = []
  /// Flattened entry IDs cached for the `VisibleEntryIDsKey` preference. Computed once
  /// per fetch (in `.task`) instead of `sections.flatMap(\.entryIDs)` on every body
  /// re-eval — meaningful for large categories ("uncategorized" with thousands of IDs).
  @State
  private var allVisibleEntryIDs: [PersistentIdentifier] = []
  @State
  private var hasLoaded = false
  /// Carries the anchor row + alignment from `reload()`'s pre-diff inspection
  /// to the post-diff `proxy.scrollTo` call. The pin is conditional on what
  /// `reload()` sees in the new result and is set to `nil` when no restore is
  /// warranted (selection cleared with no fallback, structural reload, or
  /// empty case). Kept as state because the producer and consumer sit in the
  /// same async function but bracket the `sections = result` assignment.
  @State
  private var pendingAnchorRestore: AnchorRestore?

  /// Anchor + alignment pair for `ScrollViewReader.scrollTo`. `.center` keeps
  /// a still-selected row visible after a Read/Unread filter flip or a
  /// classification batch reshuffle; `.top` keeps the previously-first row
  /// pinned at the top when a sync page lands new entries above it (so the
  /// viewport stays visually stable rather than scrolling along with the
  /// insert).
  private struct AnchorRestore: Equatable {
    let id: PersistentIdentifier
    let anchor: UnitPoint
  }

  var body: some View {
    // `ScrollViewReader` is transparent — it adds no chrome — and lives
    // OUTSIDE the conditional `Group`. The `.task` modifiers attach to the
    // ScrollViewReader's body and stay mounted for the lifetime of the view,
    // not for the lifetime of whichever branch is currently selected.
    //
    // The earlier shape nested `ScrollViewReader` inside the `else` branch
    // of `if !hasLoaded { ProgressView() } else if … else { ScrollViewReader { … } }`,
    // so the `.task` modifiers were only attached once `hasLoaded == true`.
    // Since `hasLoaded` only flips inside `reload()`, the tasks never ran on
    // first render and the loading spinner stuck forever.
    //
    // `proxy.scrollTo(_:anchor:)` resolves `.id(...)` tags anywhere in the
    // ScrollViewReader's subtree, so the List rows below stay reachable.
    ScrollViewReader { proxy in
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
          } else if classificationEngine.isClassifying || syncEngine.isSyncing {
            // Empty fetch WHILE sync/classification is active → calm loading,
            // NEVER "No Articles". This category's rows may not be classified/
            // persisted yet, or the reader fetch may have briefly lost to write
            // pressure — asserting "empty" here would hide real content that is
            // still arriving (`VISION.md → Core Principles`: the reader trusts
            // that nothing is hidden). The gate is deliberately NOT conditioned
            // on "no entry classified yet": once any row is classified (i.e.
            // always, in steady state) that guard is dead, so a momentarily-
            // empty category mid-sync fell through to a false "No Articles".
            // Spinner-only (no SF Symbol) by ux-guardian decision — the sidebar
            // already carries progress counts, so the middle pane stays calm and
            // avoids double-signalling. No trailing ellipsis on the headline per
            // HIG: don't label a spinning progress indicator.
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
                      .id(id)
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
      // Two tasks so refresh-only ticks (classification / sync completion)
      // do not flip `hasLoaded` back to false and tear down the `List` —
      // which would reset scroll every time. `structuralKey` captures
      // inputs whose change means "user is looking at a different list"
      // (category / folder / filter / cutoff); only those warrant a
      // loading view. `refreshVersion` fires in place and `reload()`
      // skips the assign when sections are equal, so SwiftUI's diff
      // keeps the scroll stable.
      //
      // The refresh task's id intentionally includes `structuralKey`:
      // a bare `refreshVersion` id would not be cancelled when the user
      // switches category mid-refresh, and the in-flight fetch — which
      // captured `self` with the old category — could race the
      // structural task and overwrite `sections` with stale rows from
      // the previous list. Including `structuralKey` cancels the stale
      // refresh when context changes, and the `guard hasLoaded` check
      // keeps the restarted refresh a no-op while the structural task
      // owns the reload.
      .task(id: structuralKey) {
        // C3 perception/occupancy (issue #138): bracket the panel-2 loading
        // window (`hasLoaded` false → true). `defer` closes it even if the
        // task is cancelled mid-reload by a structural-key change.
        let signpost = perfSignposter.beginInterval(PerformanceSignpostName.structuralReload)
        defer { perfSignposter.endInterval(PerformanceSignpostName.structuralReload, signpost) }
        hasLoaded = false
        await reload(proxy: proxy)
        hasLoaded = true
      }
      .task(id: refreshTaskKey) {
        guard hasLoaded else { return }
        await reload(proxy: proxy)
      }
    }
  }

  private func reload(proxy: ScrollViewProxy) async {
    let result =
      (try? await reader.fetchEntrySections(
        category: category, folder: folder, showRead: filter == .read,
        cutoffDate: cutoffDate, pinnedFeedbinEntryID: pinnedFeedbinEntryID
      )) ?? .empty
    guard !Task.isCancelled else { return }
    guard result.sections != sections else { return }
    // Decide whether the upcoming in-place diff warrants a scroll-anchor
    // restore. Two reasons to pin: (1) the selected row still appears in the
    // new result — keep it centred so a row-height shift (read/unread
    // weight flip) doesn't push it off-screen; (2) selection cleared and
    // the previously-first row still appears — keep the top stable when a
    // sync page lands new entries above it (option (a) per the design's
    // sync-arriving-entries autonomy decision). Structural reloads
    // (`hasLoaded == false` going into `reload`) skip the fallback so we do
    // not pin an anchor from the previous list's contents.
    //
    // `result.allEntryIDs` is precomputed off-MainActor by
    // `DataReader.fetchEntrySections` so the membership-check `Set` build is
    // the only per-reload allocation on MainActor — the flatMap walk that
    // used to live here moved to the reader.
    let newIDs = Set(result.allEntryIDs)
    let restore: AnchorRestore?
    if let selectedID = selectedEntry?.persistentModelID, newIDs.contains(selectedID) {
      restore = AnchorRestore(id: selectedID, anchor: .center)
    } else if selectedEntry == nil, hasLoaded, let firstID = allVisibleEntryIDs.first,
      newIDs.contains(firstID)
    {
      restore = AnchorRestore(id: firstID, anchor: .top)
    } else {
      restore = nil
    }
    pendingAnchorRestore = restore
    sections = result.sections
    allVisibleEntryIDs = result.allEntryIDs
    // Yield one tick so SwiftUI applies the diff before we ask the proxy
    // to scroll — without the yield `scrollTo` runs against the still-old
    // layout and the anchor row is not yet on screen to scroll to. Instant
    // scroll (no `withAnimation`) so the restore respects Reduce Motion.
    if let restore = pendingAnchorRestore {
      pendingAnchorRestore = nil
      await Task.yield()
      proxy.scrollTo(restore.id, anchor: restore.anchor)
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

#Preview("Loading - Sync Active (rows exist elsewhere)") {
  EntryListSyncActiveWithRowsPreview()
}

#Preview("Empty - No Articles (at rest)") {
  EntryListEmptyAtRestPreview()
}

/// Renders `EntryListView` in the offline-empty state: container is seeded
/// but contains no entries, and `SyncEngine.lastError` is set to `.network`
/// so the view picks the `ContentUnavailableView("Offline", …)` branch.
@MainActor
private struct EntryListOfflinePreview: View {
  @State
  private var reader: DataReader?
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
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
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
      reader = await DataReader.makeDetached(modelContainer: container)
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
  private var reader: DataReader?
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
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
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
      reader = await DataReader.makeDetached(modelContainer: container)
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
  private var reader: DataReader?
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
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
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
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the WIDENED calm-loading state (issue #137): a
/// classified article exists in ANOTHER category ("world"), classification is
/// mid-batch, and the queried category ("apple") fetch returns empty. The view
/// must show calm loading — NEVER "No Articles" — because rows may still be
/// arriving. Before #137 this fell through to a false "No Articles" (the probe
/// was non-empty once any row was classified). This is the regression guard.
@MainActor
private struct EntryListSyncActiveWithRowsPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntry: Entry?
  private let container: ModelContainer = {
    let container = PreviewSupport.makeContainer()
    let context = container.mainContext
    let feed = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "World Feed",
      feedURL: "https://world.example.com/feed", siteURL: "https://world.example.com",
      createdAt: .now)
    context.insert(feed)
    let entry = Entry(
      feedbinEntryID: 1, title: "A World Story", author: "Bot",
      url: "https://world.example.com/1", content: "<p>Story.</p>", summary: "Story",
      extractedContentURL: nil, publishedAt: .now, createdAt: .now)
    entry.feed = feed
    entry.primaryCategory = "world"
    entry.primaryFolder = "news"
    entry.isClassified = true
    entry.plainText = "Story."
    context.insert(entry)
    try? context.save()
    return container
  }()
  private let syncEngine = SyncEngine()
  private let classificationEngine: ClassificationEngine = {
    let engine = ClassificationEngine()
    engine.applyPreviewState(
      isClassifying: true,
      progress: "Categorizing 3/8",
      classifiedCount: 3,
      totalToClassify: 8
    )
    return engine
  }()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
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
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the genuine empty state at rest (issue #137): no
/// rows, and neither sync nor classification is active → "No Articles" stays
/// reachable. The widened calm-loading gate must NOT swallow the real empty
/// state once background work is at rest.
@MainActor
private struct EntryListEmptyAtRestPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntry: Entry?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine = SyncEngine()
  private let classificationEngine = ClassificationEngine()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
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
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}
