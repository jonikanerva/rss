import SwiftUI

// MARK: - Sidebar DTOs
//
// Cross-actor-safe snapshots of the sidebar's input model. They must carry
// only strings and labels, never a `@Model` reference, so the `Equatable`
// comparison stays structural and never crosses the SwiftData actor boundary
// or faults a model.

/// Snapshot of one expanded folder row plus the labels of its child
/// categories. The order in `categoryLabels` is the order the categories
/// render in the sidebar.
nonisolated struct SidebarFolderGroup: Sendable, Equatable, Identifiable {
  let label: String
  let displayName: String
  let categories: [SidebarCategorySnapshot]

  var id: String { label }
}

/// Snapshot of one selectable category row: the stable `label` that becomes
/// the selection payload, plus the user-visible `displayName`.
nonisolated struct SidebarCategorySnapshot: Sendable, Equatable, Identifiable {
  let label: String
  let displayName: String

  var id: String { label }
}

// MARK: - Sidebar View

/// The sidebar column, `Equatable` over DTO snapshots so `EquatableView` at the
/// call site can skip its body whenever the structural inputs match the
/// previous render. Keyboard navigation and mark-read overlay flips mutate
/// state that feeds none of these inputs, so they never re-render the sidebar.
///
/// The header lives inside this view and reads the engines from
/// `@Environment`: the `Equatable` skip short-circuits the outer body only, so
/// nested observation still re-renders the header as sync progresses. The
/// toolbar stays at the call site, outside the wrap, so it keeps observing the
/// engines.
struct SidebarView: View, Equatable {
  let visibleFolderGroups: [SidebarFolderGroup]
  let rootCategories: [SidebarCategorySnapshot]
  let categoryUnreadCounts: [String: Int]
  let folderUnreadCounts: [String: Int]
  let fontBody: Font
  let canMarkAllRead: Bool
  let onMarkAllRead: (SidebarSelection) -> Void
  @Binding
  var selection: SidebarSelection?
  @Binding
  var collapsedFolders: SidebarCollapsedFolders

  static func == (lhs: Self, rhs: Self) -> Bool {
    // Compare the bindings' wrapped values, not the bindings: SwiftUI hands
    // back the same projection on every rebuild, while selection identity and
    // the collapsed-folder set are part of the render contract.
    //
    // `fontBody` and `canMarkAllRead` must stay in the comparison. The rows
    // read them through these `let`s, so without them a text-size change
    // leaves the titles at the previous font, and a filter flip leaves the row
    // menus stale, until some other structural input moves.
    //
    // `onMarkAllRead` stays out of the comparison. A skipped body keeps the
    // closure of an earlier value, so the closure must read the owner's state
    // when it runs, never a value captured when the body was built.
    lhs.visibleFolderGroups == rhs.visibleFolderGroups
      && lhs.rootCategories == rhs.rootCategories
      && lhs.categoryUnreadCounts == rhs.categoryUnreadCounts
      && lhs.folderUnreadCounts == rhs.folderUnreadCounts
      && lhs.selection == rhs.selection
      && lhs.collapsedFolders == rhs.collapsedFolders
      && lhs.fontBody == rhs.fontBody
      && lhs.canMarkAllRead == rhs.canMarkAllRead
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

  /// A folder row and its child categories, as a `DisclosureGroup`. The label
  /// carries the folder selection tag, so the folder aggregate stays selectable
  /// by click and by J/K. The unread counts arrive as computed dictionaries, so
  /// the row builder never re-aggregates per render.
  ///
  /// The accessibility identifier must sit on the leaf title `Text`, not on the
  /// `DisclosureGroup` label: XCUITest does not flatten an `HStack`-shaped
  /// label into a discoverable `staticText`. No ancestor ignores its children,
  /// so VoiceOver still combines the row.
  @ViewBuilder
  private func folderGroup(_ group: SidebarFolderGroup) -> some View {
    DisclosureGroup(
      isExpanded: SidebarCollapsedFolders.expansionBinding(
        for: group.label, store: $collapsedFolders
      )
    ) {
      ForEach(group.categories) { category in
        categoryRow(category)
      }
    } label: {
      rowLabel(
        title: group.displayName,
        count: folderUnreadCounts[group.label, default: 0],
        titleAccessibilityIdentifier: "sidebar.folder.\(group.label)"
      )
      .tag(SidebarSelection.folder(group.label))
      .contextMenu { markAllReadMenu(for: .folder(group.label)) }
    }
  }

  /// One selectable category row with its unread badge, shared by in-folder
  /// children and root categories. The identifier sits on the title `Text` for
  /// the same reason as in `folderGroup`.
  @ViewBuilder
  private func categoryRow(_ category: SidebarCategorySnapshot) -> some View {
    rowLabel(
      title: category.displayName,
      count: categoryUnreadCounts[category.label, default: 0],
      titleAccessibilityIdentifier: "sidebar.category.\(category.label)"
    )
    .tag(SidebarSelection.category(category.label))
    .contextMenu { markAllReadMenu(for: .category(category.label)) }
  }

  /// The target is fixed per row. Never derive it from the selection.
  @ViewBuilder
  private func markAllReadMenu(for target: SidebarSelection) -> some View {
    if canMarkAllRead {
      Button("Mark All as Read") { onMarkAllRead(target) }
    }
  }

  /// Shared row layout: title left, quiet count right, with a stable trailing
  /// column. `titleAccessibilityIdentifier` goes on the leaf `Text`, so
  /// XCUITest can find the row.
  @ViewBuilder
  private func rowLabel(title: String, count: Int, titleAccessibilityIdentifier: String) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(fontBody)
        .lineLimit(1)
        .accessibilityIdentifier(titleAccessibilityIdentifier)
      Spacer(minLength: 4)
      SidebarUnreadBadge(count: count)
    }
  }
}

// MARK: - Previews

@MainActor
private enum SidebarPreviewFixtures {
  static let folderGroups = [
    SidebarFolderGroup(
      label: "technology", displayName: "Technology",
      categories: [
        SidebarCategorySnapshot(label: "apple", displayName: "Apple"),
        SidebarCategorySnapshot(label: "ai", displayName: "Artificial Intelligence and Machine Learning Research"),
        SidebarCategorySnapshot(label: "home_automation", displayName: "Home Automation"),
      ]),
    SidebarFolderGroup(
      label: "gaming", displayName: "Gaming, Consoles, and Interactive Entertainment",
      categories: [SidebarCategorySnapshot(label: "video_games", displayName: "Video Games")]),
  ]
  static let rootCategories = [SidebarCategorySnapshot(label: "science", displayName: "Science")]
  static let categoryUnreadCounts = ["apple": 3, "ai": 1284, "home_automation": 0, "video_games": 3, "science": 0]
  static let folderUnreadCounts = ["technology": 1287, "gaming": 3]

  static func sidebar(
    textSize: AppTextSize, selection: Binding<SidebarSelection?>, collapsedFolders: Binding<SidebarCollapsedFolders>
  ) -> some View {
    let fontSettings = AppFontSettings(textSize: textSize)
    return SidebarView(
      visibleFolderGroups: folderGroups,
      rootCategories: rootCategories,
      categoryUnreadCounts: categoryUnreadCounts,
      folderUnreadCounts: folderUnreadCounts,
      fontBody: fontSettings.body,
      canMarkAllRead: true,
      onMarkAllRead: { _ in },
      selection: selection,
      collapsedFolders: collapsedFolders
    )
    .environment(fontSettings)
    .environment(SyncEngine.preview())
    .environment(ClassificationEngine())
    .frame(width: ColumnWidthSetting.Column.sidebar.defaultIdealWidth, height: 520)
  }
}

#Preview("Sidebar - Folders") {
  @Previewable
  @State
  var selection: SidebarSelection? = .category("apple")
  @Previewable
  @State
  var collapsed = SidebarCollapsedFolders(labels: ["gaming"])
  SidebarPreviewFixtures.sidebar(textSize: .medium, selection: $selection, collapsedFolders: $collapsed)
}

#Preview("Sidebar - Huge") {
  @Previewable
  @State
  var selection: SidebarSelection? = .category("apple")
  @Previewable
  @State
  var collapsed = SidebarCollapsedFolders(labels: ["gaming"])
  SidebarPreviewFixtures.sidebar(textSize: .xxLarge, selection: $selection, collapsedFolders: $collapsed)
}
