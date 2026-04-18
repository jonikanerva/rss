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
  @Binding
  var selectedEntry: Entry?
  let onMarkAllRead: () -> Void

  @Environment(\.modelContext)
  private var modelContext
  @State
  private var sections: [EntryListSection] = []
  /// Flattened entry IDs cached for the `VisibleEntryIDsKey` preference. Computed once
  /// per fetch (in `.task`) instead of `sections.flatMap(\.entryIDs)` on every body
  /// re-eval — meaningful for large categories ("uncategorized" with thousands of IDs).
  @State
  private var allVisibleEntryIDs: [PersistentIdentifier] = []
  @State
  private var hasLoaded = false

  var body: some View {
    Group {
      if !hasLoaded {
        ProgressView()
          .controlSize(.regular)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("timeline.loading")
      } else if sections.isEmpty {
        ContentUnavailableView {
          Label("No Articles", systemImage: "newspaper")
        } description: {
          Text(
            filter == .unread
              ? "No unread articles in this category."
              : "No read articles in this category."
          )
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
                .font(.system(size: FontTheme.captionSize, weight: .medium))
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
        category: category, folder: folder, showRead: filter == .read, cutoffDate: cutoffDate
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
