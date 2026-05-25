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

/// The article-list column's sidebar, extracted from `ContentView` to
/// reduce body-eval cost: the row builders see DTO snapshots instead of
/// `@Model` faulting calls, and the `unreadCounts` aggregation runs once
/// per outer body eval rather than once per row.
///
/// The header (`SyncStatusView`) intentionally lives inside this view
/// and reads `SyncEngine` / `ClassificationEngine` from `@Environment`.
/// Those reads observe their own `@Observable` properties and continue
/// to re-render the header sub-tree when sync progresses.
///
/// A previous iteration of this PR wrapped the call site in
/// `EquatableView(content:)` for an extra render-skip. That short-circuit
/// hid the sidebar from XCUITest accessibility queries
/// (`sidebar.folder.<label>` static texts did not register on first
/// render in demo mode), so the wrapper was removed — SwiftUI's natural
/// diff handles the render-skip well enough now that the row builders
/// no longer touch `@Model` types.
struct SidebarView: View {
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
