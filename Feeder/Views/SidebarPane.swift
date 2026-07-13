import SwiftData
import SwiftUI
import os.signpost

// MARK: - Taxonomy mirror value

/// Equatable bundle of everything `ReadingSelection`'s taxonomy mirrors
/// derive from. Computed per `SidebarPane` body pass from the pane's own
/// inputs (the taxonomy queries + collapse state) and pushed into the nav
/// model by `.onChange` — never read back in a body.
nonisolated struct SidebarTaxonomyMirror: Equatable {
  let items: [SidebarSelection]
  let displayNames: [SidebarSelection: String]
}

// MARK: - Sidebar Pane (issue #146 final fix)

/// Owns the taxonomy `@Query`s and the collapse state — the ONLY inputs its
/// body reads. It reads NEITHER observable model in body, so a category /
/// selection switch never re-evaluates this pane: the sidebar DTO
/// construction (the `@Model` `.label` / `.displayName` reads the #146
/// diagnosis indicts — they ran BEFORE `EquatableView` could compare) now
/// runs ONLY on a taxonomy change. The models are held via `@Environment`
/// for the `.onChange` closures only — holding a reference forms no
/// Observation dependency; only a body READ does.
///
/// Responsibilities: build the sidebar DTO snapshots (+ emit the countable
/// `sidebar-snapshot-build` event), push the taxonomy mirrors into
/// `ReadingSelection` (SOLE mirror writer) and revalidate the selection on
/// taxonomy changes, and bump the article-list refresh when a category
/// moves between folders (`CategoryFolderChangeTrigger` — re-homed here
/// with `categoryFolderLabels`, since only this pane owns the queries).
struct SidebarPane: View {
  let panelFocus: FocusState<PanelFocus?>.Binding
  let onMarkAllRead: () -> Void
  let onSyncAndClassify: () -> Void

  @Environment(ReadingSelection.self)
  private var nav
  @Environment(UnreadState.self)
  private var unreadState
  @Query(sort: \Folder.sortOrder)
  private var folders: [Folder]
  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]
  /// Root-level categories fetched via a SQLite-level predicate. Replaces an
  /// `allCategories.atRoot` in-memory filter on every render.
  @Query(filter: #Predicate<Category> { $0.folderLabel == nil }, sort: \Category.sortOrder)
  private var rootCategories: [Category]
  @AppStorage("sidebar.collapsedFolders")
  private var collapsedFolders: SidebarCollapsedFolders = .init()

  var body: some View {
    // Sub-cost meter (issue #146): the owner's re-trace counts these events
    // per selection switch — the "sidebar @Model reads ≈ 0 per selection"
    // gate, countable instead of inferred. Zero-cost with no profiler.
    perfSignposter.emitEvent(PerformanceSignpostName.sidebarSnapshotBuild)
    return SidebarInner(
      visibleFolderGroups: sidebarFolderGroupSnapshots,
      rootCategories: sidebarRootCategorySnapshots,
      folderCount: folders.count,
      categoryCount: allCategories.count,
      collapsedFolders: $collapsedFolders,
      onMarkAllRead: onMarkAllRead,
      onSyncAndClassify: onSyncAndClassify
    )
    .focused(panelFocus, equals: .sidebar)
    // Taxonomy sync: push the mirrors into the nav model whenever the
    // taxonomy or the collapse state changes (initial: true covers first
    // render), then revalidate — replaces the pre-split
    // `onChange(of: folders.count)` / `onChange(of: allCategories.count)`
    // revalidation triggers and additionally reacts to renames.
    .onChange(of: taxonomyMirror, initial: true) { _, mirror in
      nav.updateTaxonomy(items: mirror.items, displayNames: mirror.displayNames)
      nav.revalidateSelection()
    }
    // A category moving between folders changes what the folder-axis lists
    // show — refresh the article list (re-homed with the queries, da rider 2).
    .modifier(
      CategoryFolderChangeTrigger(
        categoryFolderLabels: categoryFolderLabels,
        onChange: { unreadState.noteDataChanged() }
      )
    )
  }

  // MARK: - Category lookups (small count, acceptable in-memory filter)

  /// Filter+sort the folder list down to those with at least one category,
  /// paired with their categories. Only folders with at least one assigned
  /// category are surfaced — empty folders carry no sidebar weight.
  private var visibleFolderGroups: [(folder: Folder, categories: [Category])] {
    folders.compactMap { folder in
      let categoriesInFolder = allCategories.inFolder(folder.label)
      guard !categoriesInFolder.isEmpty else { return nil }
      return (folder, categoriesInFolder)
    }
  }

  /// Snapshot of folder groups in DTO form, passed into the `Equatable`
  /// `SidebarView` (via `SidebarInner`) so SwiftUI compares structural
  /// snapshots without crossing the SwiftData actor boundary.
  private var sidebarFolderGroupSnapshots: [SidebarFolderGroup] {
    visibleFolderGroups.map { group in
      SidebarFolderGroup(
        label: group.folder.label,
        displayName: group.folder.displayName,
        categories: group.categories.map { category in
          SidebarCategorySnapshot(label: category.label, displayName: category.displayName)
        }
      )
    }
  }

  /// Snapshot of root-level categories in DTO form. Same rationale as
  /// `sidebarFolderGroupSnapshots`.
  private var sidebarRootCategorySnapshots: [SidebarCategorySnapshot] {
    rootCategories.map { category in
      SidebarCategorySnapshot(label: category.label, displayName: category.displayName)
    }
  }

  /// Snapshot of every category's folder assignment. Watched by
  /// `CategoryFolderChangeTrigger` so moving a category between folders
  /// refreshes the article list.
  private var categoryFolderLabels: [String?] {
    allCategories.map(\.folderLabel)
  }

  /// Everything the nav model's taxonomy mirrors derive from. The visible
  /// keyboard-order items are collapse-aware (J/K skips collapsed
  /// children); `displayNames` covers EVERY folder and category so
  /// `revalidateSelection()` keeps its pre-split semantics (a selection
  /// inside a collapsed folder stays valid).
  private var taxonomyMirror: SidebarTaxonomyMirror {
    let groups = visibleFolderGroups.map { group in
      (folderLabel: group.folder.label, categoryLabels: group.categories.map(\.label))
    }
    let items = sidebarNavigationItems(
      folderGroups: groups,
      rootCategoryLabels: rootCategories.map(\.label),
      collapsedFolderLabels: collapsedFolders.labels
    )
    var names: [SidebarSelection: String] = [:]
    for folder in folders {
      names[.folder(folder.label)] = folder.displayName
    }
    for category in allCategories {
      names[.category(category.label)] = category.displayName
    }
    return SidebarTaxonomyMirror(items: items, displayNames: names)
  }
}

// MARK: - Sidebar Inner (model-reading leaf)

/// The counterpart of `SidebarPane`'s model-free body: THIS leaf reads the
/// observable models (badge math + the selection binding), so volatile churn
/// — selection highlight, overlay flips, snapshot refreshes — re-evaluates
/// only this leaf: the badge subtraction plus an O(~50-row) `EquatableView`
/// compare, never the DTO construction above it.
///
/// Design note (accepted, do not "fix"): `unreadSnapshotKey` reads
/// `unreadState.refreshVersion` in this body, so a mid-classification tick
/// (~1/s) re-evaluates this leaf. That cost is bounded to the badge math +
/// the `EquatableView` compare — deliberately accepted.
struct SidebarInner: View {
  let visibleFolderGroups: [SidebarFolderGroup]
  let rootCategories: [SidebarCategorySnapshot]
  /// Raw taxonomy counts for `unreadSnapshotKey` — passed from
  /// `SidebarPane`'s queries so the key keeps its pre-split semantics
  /// (`folders.count` includes empty folders, which the visible DTO groups
  /// exclude).
  let folderCount: Int
  let categoryCount: Int
  @Binding
  var collapsedFolders: SidebarCollapsedFolders
  let onMarkAllRead: () -> Void
  let onSyncAndClassify: () -> Void

  @Environment(ReadingSelection.self)
  private var nav
  @Environment(UnreadState.self)
  private var unreadState
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(AppFontSettings.self)
  private var fontSettings

  var body: some View {
    @Bindable
    var nav = nav
    // Sidebar badge counts derive from the cached snapshot, refreshed
    // off-MainActor by `DataReader.fetchUnreadCountsSnapshot()` — the body
    // never re-aggregates. `pendingReadIDs` is the optimistic-read overlay
    // that already drives the dimmed state in `EntryRowView`; subtracting it
    // here keeps the badges in step with the article list in the same frame,
    // without flipping `isRead` eagerly. The subtraction is bounded by the
    // category/folder count times the overlay size — both small. The
    // intersection against `unreadIDByCategory` / `unreadIDByFolder`
    // naturally excludes pending IDs that are no longer unread on disk, so a
    // stale cross-device flip cannot double-subtract.
    let pendingByCategory = pendingReadCountsByCategory(
      snapshot: unreadState.snapshot, pending: unreadState.pendingReadIDs)
    let pendingByFolder = pendingReadCountsByFolder(
      snapshot: unreadState.snapshot, pending: unreadState.pendingReadIDs)
    let categoryUnreadCounts = unreadState.snapshot.categoryCounts
      .subtractingPendingCounts(pendingByCategory)
    let folderUnreadCounts = unreadState.snapshot.folderCounts
      .subtractingPendingCounts(pendingByFolder)
    // EquatableView short-circuits the sidebar body whenever the structural
    // inputs above match the previous render — mark-read overlay flips,
    // selection changes, and detail-pane state never cross into the
    // sidebar's render path. Toolbar + key handlers stay outside so they
    // remain reactive to `syncEngine.isSyncing` / class-engine state.
    return EquatableView(
      content: SidebarView(
        visibleFolderGroups: visibleFolderGroups,
        rootCategories: rootCategories,
        categoryUnreadCounts: categoryUnreadCounts,
        folderUnreadCounts: folderUnreadCounts,
        fontBody: fontSettings.body,
        selection: $nav.selection,
        collapsedFolders: $collapsedFolders
      )
    )
    .modifier(BareKeyHandler())
    .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
    .accessibilityIdentifier("sidebar.list")
    .toolbar {
      ToolbarItem {
        Button {
          onSyncAndClassify()
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
        .accessibilityIdentifier("toolbar.sync")
      }
    }
    // Refresh the cached unread snapshot whenever the underlying data may
    // have changed. Lives HERE (not on the pane) so its key — which reads
    // `unreadState.refreshVersion` — never dirties the DTO builder above.
    .modifier(
      UnreadSnapshotRefreshTask(
        key: unreadSnapshotKey,
        reader: syncEngine.reader,
        cutoffDate: syncEngine.queryCutoffDate,
        apply: { unreadState.applySnapshot($0) }
      )
    )
    // Keep the overlay aligned with the live snapshot: when a background
    // write flips entries out of the snapshot, the two-sided prune releases
    // the confirmed IDs so the set does not grow unbounded across a session.
    .modifier(
      PendingReadPruneTrigger(
        unreadCount: unreadState.snapshot.totalUnread,
        onUnreadCountChange: { unreadState.prune() }
      )
    )
  }

  /// Re-key for the snapshot refresh task. Bumps on `refreshVersion` (every
  /// mutation path that can change unread membership), the raw taxonomy
  /// counts (keyspace edits without an entry flip), and the cutoff (Settings
  /// changes to `articleKeepDays` must re-align the badges with
  /// `fetchEntrySections`). Cutoff cast to whole seconds truncates
  /// sub-second jitter; `refreshVersion` wraps via `&+=` and the string
  /// compare handles the wrap.
  private var unreadSnapshotKey: String {
    let cutoffSeconds = Int(syncEngine.queryCutoffDate.timeIntervalSinceReferenceDate)
    return "\(unreadState.refreshVersion)|\(folderCount)|\(categoryCount)|\(cutoffSeconds)"
  }
}

// MARK: - Preview

#Preview("Sidebar — 8 folders × 6 categories") {
  SidebarPanePreview()
}

/// Realistic-scale sidebar fixture (~50 selectable rows): eight folders with
/// six categories each — the badge-math and `EquatableView`-compare scale
/// the #146 diagnosis measured against. Drives the REAL pane, so the
/// taxonomy-mirror sync and DTO construction run exactly as shipped.
@MainActor
private struct SidebarPanePreview: View {
  @FocusState
  private var panelFocus: PanelFocus?
  @State
  private var nav = ReadingSelection()
  @State
  private var unreadState = UnreadState()
  private let container: ModelContainer = {
    let container = PreviewSupport.makeContainer()
    let context = container.mainContext
    for folderIndex in 0..<8 {
      let folder = Folder(
        label: "folder_\(folderIndex)", displayName: "Folder \(folderIndex)",
        sortOrder: folderIndex)
      context.insert(folder)
      for categoryIndex in 0..<6 {
        let category = Category(
          label: "cat_\(folderIndex)_\(categoryIndex)",
          displayName: "Category \(folderIndex).\(categoryIndex)",
          categoryDescription: "Preview category",
          sortOrder: folderIndex * 10 + categoryIndex,
          folderLabel: "folder_\(folderIndex)")
        context.insert(category)
      }
    }
    try? context.save()
    return container
  }()
  private let syncEngine = SyncEngine()
  private let classificationEngine = ClassificationEngine()

  var body: some View {
    SidebarPane(
      panelFocus: $panelFocus,
      onMarkAllRead: {},
      onSyncAndClassify: {}
    )
    .environment(nav)
    .environment(unreadState)
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 260, height: 640)
  }
}
