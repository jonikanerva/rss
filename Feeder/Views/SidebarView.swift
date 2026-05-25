import SwiftUI

// MARK: - Sidebar DTOs
//
// Cross-actor-safe snapshots of the sidebar's input model. They carry only
// strings and labels — never a `@Model` reference — so the `Equatable` shape
// is structural and SwiftUI can compare two `SidebarView` instances in O(n)
// without crossing the SwiftData actor boundary or triggering any `@Model`
// faulting. Same pattern as `EntryListSection` / `DataWriterDTOs`.

/// Snapshot of one expanded folder row plus the labels of its child
/// categories. The order in `categoryLabels` is the order the categories
/// render in the sidebar.
nonisolated struct SidebarFolderGroup: Sendable, Equatable, Identifiable {
  let label: String
  let displayName: String
  let categories: [SidebarCategorySnapshot]

  var id: String { label }
}

/// Snapshot of one selectable category row. Carries only what the sidebar
/// row builder needs: stable `label` (used as `SidebarSelection.category`'s
/// payload) plus the user-visible `displayName`.
nonisolated struct SidebarCategorySnapshot: Sendable, Equatable, Identifiable {
  let label: String
  let displayName: String

  var id: String { label }
}

// MARK: - Sidebar View

/// The article-list column's sidebar, extracted from `ContentView` so
/// SwiftUI can skip re-rendering it when nothing the sidebar depends on
/// has changed.
///
/// The view is `Equatable` and its inputs are DTO snapshots (plus two
/// `@Binding`s that SwiftUI keeps stable across body re-evaluations).
/// `ContentView` wraps the call site in `EquatableView(content:)`, which
/// is the documented Apple primitive for "render-skip when `==` returns
/// true". The hot path (arrow-key keyboard nav, mark-as-read overlay
/// flips) mutates state that does not feed any of the `let` inputs here,
/// so the sidebar's body is no longer re-evaluated on those events.
///
/// The header (`SyncStatusView`) intentionally lives inside this view
/// and reads `SyncEngine` / `ClassificationEngine` from `@Environment`.
/// Those reads observe their own `@Observable` properties and continue
/// to re-render the header sub-tree when sync progresses — the
/// `Equatable` skip only short-circuits the outer body, not nested
/// observation. The toolbar stays at the `ContentView` call site (outside
/// the `EquatableView`) so it stays reactive to
/// `syncEngine.isSyncing || classificationEngine.isClassifying`.
struct SidebarView: View, Equatable {
  let visibleFolderGroups: [SidebarFolderGroup]
  let rootCategories: [SidebarCategorySnapshot]
  let categoryUnreadCounts: [String: Int]
  let folderUnreadCounts: [String: Int]
  let collapsedFolders: SidebarCollapsedFolders
  let fontBody: Font
  @Binding
  var selection: SidebarSelection?
  @Binding
  var collapsedFoldersBinding: SidebarCollapsedFolders

  static func == (lhs: Self, rhs: Self) -> Bool {
    // `@Binding`-wrapped properties expose their `wrappedValue` directly via
    // the dot-accessor on the view instance, which is what we need here:
    // selection identity is part of the render contract. Bindings themselves
    // are stable across re-evals — SwiftUI hands the same projection on each
    // re-build — so comparing the wrapped value is the meaningful check.
    //
    // `fontBody` is read by `rowLabel(title:count:)` — without it in the
    // comparison, changing the app text size in Settings would leave the
    // sidebar row titles stuck at the previous font until some other
    // structural input (sync state, selection, classification batch)
    // changed. `SidebarUnreadBadge` and `SyncStatusView` self-observe
    // `AppFontSettings`, but the row title text reads through this `let`.
    lhs.visibleFolderGroups == rhs.visibleFolderGroups
      && lhs.rootCategories == rhs.rootCategories
      && lhs.categoryUnreadCounts == rhs.categoryUnreadCounts
      && lhs.folderUnreadCounts == rhs.folderUnreadCounts
      && lhs.collapsedFolders == rhs.collapsedFolders
      && lhs.selection == rhs.selection
      && lhs.fontBody == rhs.fontBody
  }

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(visibleFolderGroups) { group in
          folderGroup(group)
        }
        ForEach(rootCategories) { category in
          categoryRow(category)
        }
      } header: {
        SyncStatusView()
      }
    }
    .listStyle(.sidebar)
  }

  // MARK: - Row builders

  /// A folder row plus its child categories rendered as a `DisclosureGroup`.
  /// The label carries the folder selection tag so the folder aggregate stays
  /// selectable (J/K nav and click). The trailing unread count is a
  /// `SidebarUnreadBadge` rather than `.badge(_:)` so we control its font
  /// and contrast — `.badge` renders a high-contrast system pill on macOS
  /// that has no public styling hook and clashed with the calm reader
  /// surface (`docs/vision.md`). Unread counts are passed in as
  /// already-computed dictionaries so the row builder never re-aggregates
  /// per render.
  @ViewBuilder
  private func folderGroup(_ group: SidebarFolderGroup) -> some View {
    DisclosureGroup(
      isExpanded: SidebarCollapsedFolders.expansionBinding(
        for: group.label, store: $collapsedFoldersBinding
      )
    ) {
      ForEach(group.categories) { category in
        categoryRow(category)
      }
    } label: {
      rowLabel(
        title: group.displayName,
        count: folderUnreadCounts[group.label, default: 0]
      )
      .tag(SidebarSelection.folder(group.label))
      .accessibilityIdentifier("sidebar.folder.\(group.label)")
    }
  }

  /// A single selectable category row with its unread badge. Shared by
  /// in-folder children and root-level categories.
  @ViewBuilder
  private func categoryRow(_ category: SidebarCategorySnapshot) -> some View {
    rowLabel(
      title: category.displayName,
      count: categoryUnreadCounts[category.label, default: 0]
    )
    .tag(SidebarSelection.category(category.label))
    .accessibilityIdentifier("sidebar.category.\(category.label)")
  }

  /// Shared row layout for sidebar entries — folder labels and category
  /// labels both need "title left, quiet count right". Lifting this avoids
  /// duplicating the `HStack` + `Spacer()` + `SidebarUnreadBadge` triplet
  /// in two call sites and gives the count a stable trailing column.
  @ViewBuilder
  private func rowLabel(title: String, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(fontBody)
        .lineLimit(1)
      Spacer(minLength: 4)
      SidebarUnreadBadge(count: count)
    }
  }
}
