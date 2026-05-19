import SwiftData
import SwiftUI

// MARK: - Category Management View

struct CategoryManagementView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings

  @Query(sort: \Folder.sortOrder)
  private var folders: [Folder]

  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]

  /// Root-level categories fetched via a SQLite-level predicate. Replaces an
  /// `allCategories.atRoot` in-memory filter in the render path.
  @Query(filter: #Predicate<Category> { $0.folderLabel == nil }, sort: \Category.sortOrder)
  private var rootCategories: [Category]

  @State
  private var editingCategory: Category?
  @State
  private var editingFolder: Folder?
  @State
  private var showNewCategorySheet = false
  @State
  private var showNewFolderSheet = false
  /// Tracks which folder row is selected in the management list. Selection
  /// activates the row's context-menu keyboard shortcuts (Cmd+[ / Cmd+]) so
  /// the user can reorder folders without reaching for the mouse.
  @State
  private var selectedFolderLabel: String?

  var body: some View {
    VStack(spacing: 0) {
      if allCategories.isEmpty && folders.isEmpty {
        emptyState
      } else {
        categoryList
      }
      Divider()
      actionButtons
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    .sheet(isPresented: $showNewCategorySheet) {
      CategoryEditSheet(category: nil, folders: folders)
    }
    .sheet(isPresented: $showNewFolderSheet) {
      FolderEditSheet(folder: nil)
    }
    .sheet(item: $editingCategory) { category in
      CategoryEditSheet(category: category, folders: folders)
    }
    .sheet(item: $editingFolder) { folder in
      FolderEditSheet(folder: folder)
    }
  }

  // MARK: - List content

  @ViewBuilder
  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Categories", systemImage: "tag")
    } description: {
      Text("Create categories to classify your articles.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// `.onMove` is only synthesized inside `List`, not `Form` — so the list of
  /// categories lives in a `List` even though the surrounding screen is a
  /// settings tab. One `Section` per folder plus a trailing root section.
  /// `.onMove` on each folder reorders that folder's children in place;
  /// cross-folder moves use the row context menu. The system category gets
  /// `.moveDisabled(true)` so "uncategorized" never drifts out of place.
  ///
  /// The list carries a `selection` binding for the focused folder row. That
  /// selection activates the folder context-menu shortcuts (Cmd+[ / Cmd+]),
  /// satisfying the keyboard-navigation mandate alongside the drag affordance.
  @ViewBuilder
  private var categoryList: some View {
    List(selection: $selectedFolderLabel) {
      ForEach(folders) { folder in
        folderSection(folder: folder)
      }
      .onMove { indices, newOffset in
        reorderFolders(source: indices, destination: newOffset)
      }
      rootSection
    }
  }

  @ViewBuilder
  private func folderSection(folder: Folder) -> some View {
    let children = allCategories.inFolder(folder.label)
    Section {
      folderHeaderRow(folder: folder)
      ForEach(children, id: \.persistentModelID) { child in
        categoryRow(child, depth: 1)
      }
      .onMove { indices, newOffset in
        reorder(children: children, inFolder: folder.label, source: indices, destination: newOffset)
      }
    }
  }

  /// Folder header row. Tagged so `List(selection:)` can drive the
  /// keyboard-shortcut buttons in the context menu, and given an accessibility
  /// label that announces the row's current position to VoiceOver.
  @ViewBuilder
  private func folderHeaderRow(folder: Folder) -> some View {
    let position = folderPosition(of: folder.label)
    FolderCompactRow(displayName: folder.displayName, onEdit: { editingFolder = folder })
      .tag(folder.label)
      .accessibilityLabel("Folder \(folder.displayName)")
      .accessibilityValue("position \(position) of \(folders.count)")
      .contextMenu {
        folderReorderMenu(for: folder)
      }
  }

  /// Move Up / Move Down / Move to Top / Move to Bottom buttons. Cmd+[ and
  /// Cmd+] are attached to the directional moves so the shortcuts surface in
  /// the row's context menu — discoverable per `app-rules.md` § Keyboard
  /// Navigation. Move-to-Top / Move-to-Bottom have no shortcut by design
  /// (matches Finder's Edit > Move convention).
  @ViewBuilder
  private func folderReorderMenu(for folder: Folder) -> some View {
    let canMoveUp = canMoveFolderUp(label: folder.label)
    let canMoveDown = canMoveFolderDown(label: folder.label)
    Button("Move Up") {
      moveFolder(label: folder.label, direction: .up)
    }
    .keyboardShortcut("[", modifiers: .command)
    .disabled(!canMoveUp)
    Button("Move Down") {
      moveFolder(label: folder.label, direction: .down)
    }
    .keyboardShortcut("]", modifiers: .command)
    .disabled(!canMoveDown)
    Divider()
    Button("Move to Top") {
      moveFolder(label: folder.label, direction: .top)
    }
    .disabled(!canMoveUp)
    Button("Move to Bottom") {
      moveFolder(label: folder.label, direction: .bottom)
    }
    .disabled(!canMoveDown)
  }

  @ViewBuilder
  private var rootSection: some View {
    Section {
      ForEach(rootCategories, id: \.persistentModelID) { category in
        categoryRow(category, depth: 0)
          .moveDisabled(category.isSystem)
      }
      .onMove { indices, newOffset in
        reorder(children: rootCategories, inFolder: nil, source: indices, destination: newOffset)
      }
    }
  }

  /// Per-row view. The context menu is only attached for non-system
  /// categories — gating the menu body alone would produce an empty
  /// context menu for "uncategorized".
  @ViewBuilder
  private func categoryRow(_ category: Category, depth: Int) -> some View {
    let row = CategoryCompactRow(
      displayName: category.displayName,
      descriptionPreview: category.categoryDescription,
      depth: depth,
      isSystem: category.isSystem,
      onEdit: { editingCategory = category }
    )
    if category.isSystem {
      row
    } else {
      row.contextMenu {
        moveToFolderMenu(for: category)
      }
    }
  }

  /// "Move to Folder" submenu. HIG: hide unavailable destinations (current
  /// folder, and "No Folder" when already at root) instead of disabling them.
  @ViewBuilder
  private func moveToFolderMenu(for category: Category) -> some View {
    Menu("Move to Folder") {
      if category.folderLabel != nil {
        Button("No Folder") {
          moveCategory(category, toFolder: nil)
        }
      }
      ForEach(folders.filter { $0.label != category.folderLabel }) { folder in
        Button(folder.displayName) {
          moveCategory(category, toFolder: folder.label)
        }
      }
    }
  }

  // MARK: - Footer

  private var actionButtons: some View {
    HStack {
      if classificationEngine.isClassifying {
        ProgressView()
          .scaleEffect(0.7)
        Text(classificationEngine.progress)
          .font(fontSettings.caption)
          .foregroundStyle(.secondary)
      } else {
        Button("Reclassify All") {
          Task {
            if let writer = syncEngine.writer {
              await classificationEngine.reclassifyAll(writer: writer)
            }
          }
        }
        .disabled(allCategories.isEmpty)
        .help("Re-run classification on all articles with current categories")
        .accessibilityIdentifier("categories.reclassify")
      }
      Spacer()
      Button("New Folder...") {
        showNewFolderSheet = true
      }
      .accessibilityIdentifier("folders.add")
      Button("New Category...") {
        showNewCategorySheet = true
      }
      .accessibilityIdentifier("categories.add")
    }
  }

  // MARK: - Mutations

  /// Apply a SwiftUI `.onMove` index shuffle: rebuild the label order locally,
  /// then ship just the `[String]` order across the actor boundary. `move(...)`
  /// is the standard Swift Collections helper used in tandem with `.onMove`.
  private func reorder(
    children: [Category], inFolder folderLabel: String?, source: IndexSet, destination: Int
  ) {
    guard let writer = syncEngine.writer else { return }
    var labels = children.map(\.label)
    labels.move(fromOffsets: source, toOffset: destination)
    Task {
      try? await writer.reorderCategories(inFolder: folderLabel, orderedLabels: labels)
    }
  }

  /// Apply a SwiftUI `.onMove` index shuffle to the top-level folder list.
  /// Mirrors `reorder(children:inFolder:source:destination:)` but ships the
  /// folder label order instead of the category label order.
  private func reorderFolders(source: IndexSet, destination: Int) {
    guard let movedLabel = source.first.flatMap({ folders.indices.contains($0) ? folders[$0].label : nil })
    else { return }
    var labels = folders.map(\.label)
    labels.move(fromOffsets: source, toOffset: destination)
    persistFolderOrder(labels)
    announceFolderMoveInOrder(label: movedLabel, in: labels)
  }

  private enum FolderMoveDirection {
    case up
    case down
    case top
    case bottom
  }

  /// Keyboard / context-menu folder move. Builds the resulting label order
  /// locally, then hands the `[String]` order to `DataWriter`. Selection is
  /// kept on the moved row so subsequent keyboard moves chain naturally.
  private func moveFolder(label: String, direction: FolderMoveDirection) {
    guard let currentIndex = folders.firstIndex(where: { $0.label == label }) else { return }
    var labels = folders.map(\.label)
    switch direction {
    case .up:
      guard currentIndex > 0 else { return }
      labels.swapAt(currentIndex, currentIndex - 1)
    case .down:
      guard currentIndex < labels.count - 1 else { return }
      labels.swapAt(currentIndex, currentIndex + 1)
    case .top:
      guard currentIndex > 0 else { return }
      labels.remove(at: currentIndex)
      labels.insert(label, at: 0)
    case .bottom:
      guard currentIndex < labels.count - 1 else { return }
      labels.remove(at: currentIndex)
      labels.append(label)
    }
    persistFolderOrder(labels)
    selectedFolderLabel = label
    announceFolderMoveInOrder(label: label, in: labels)
  }

  /// Ship a label order across the actor boundary. Logging is delegated to
  /// `DataWriter`; the UI side stays fire-and-forget like the existing
  /// category reorder path.
  private func persistFolderOrder(_ orderedLabels: [String]) {
    guard let writer = syncEngine.writer else { return }
    Task {
      try? await writer.reorderFolders(orderedLabels: orderedLabels)
    }
  }

  /// Post a VoiceOver announcement so screen-reader users hear the new
  /// position immediately after a programmatic move. Reads the new position
  /// from the locally-computed label order — the `@Query`-backed `folders`
  /// array only refreshes after the write round-trips through SwiftData.
  private func announceFolderMoveInOrder(label: String, in orderedLabels: [String]) {
    guard let folder = folders.first(where: { $0.label == label }),
      let newIndex = orderedLabels.firstIndex(of: label)
    else { return }
    let message = "Folder \(folder.displayName), moved to position \(newIndex + 1) of \(orderedLabels.count)"
    AccessibilityNotification.Announcement(message).post()
  }

  /// 1-indexed position of a folder for accessibility strings.
  private func folderPosition(of label: String) -> Int {
    (folders.firstIndex(where: { $0.label == label }) ?? 0) + 1
  }

  private func canMoveFolderUp(label: String) -> Bool {
    guard let index = folders.firstIndex(where: { $0.label == label }) else { return false }
    return index > 0
  }

  private func canMoveFolderDown(label: String) -> Bool {
    guard let index = folders.firstIndex(where: { $0.label == label }) else { return false }
    return index < folders.count - 1
  }

  /// Move a category between folders (or to root) via the context menu. The
  /// new sortOrder appends past the existing peers in the target — matching
  /// what `CategoryEditSheet.save()` does.
  private func moveCategory(_ category: Category, toFolder folderLabel: String?) {
    guard !category.isSystem, let writer = syncEngine.writer else { return }
    let peerCount: Int
    if let folderLabel {
      peerCount = allCategories.inFolder(folderLabel).count
    } else {
      peerCount = rootCategories.count
    }
    let label = category.label
    Task {
      try? await writer.moveCategoryToFolder(label: label, folderLabel: folderLabel, sortOrder: peerCount)
    }
  }
}

// MARK: - Preview

#Preview("Category Management") {
  categoryManagementPreview()
}

#Preview("Category Management - Empty") {
  categoryManagementEmptyPreview()
}

#Preview("Category Management - Multiple Folders") {
  categoryManagementMultipleFoldersPreview()
}

@MainActor
private func categoryManagementPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let techFolder = Folder(label: "technology", displayName: "Technology", sortOrder: 0)
  context.insert(techFolder)

  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple company news.", sortOrder: 0,
    folderLabel: "technology")
  let ai = Category(
    label: "ai", displayName: "AI", categoryDescription: "AI and ML news.", sortOrder: 1, folderLabel: "technology")
  let world = Category(label: "world_news", displayName: "World News", categoryDescription: "Global policy news.", sortOrder: 0)

  context.insert(apple)
  context.insert(ai)
  context.insert(world)
  try? context.save()

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 480, height: 500)
}

@MainActor
private func categoryManagementEmptyPreview() -> some View {
  let container = PreviewSupport.makeContainer()

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 480, height: 500)
}

/// Exercises the reorder UI states: multiple folders so Move Up / Down can be
/// enabled or disabled depending on which row is selected (top, middle,
/// bottom).
@MainActor
private func categoryManagementMultipleFoldersPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let tech = Folder(label: "technology", displayName: "Technology", sortOrder: 0)
  let gaming = Folder(label: "gaming", displayName: "Gaming", sortOrder: 1)
  let science = Folder(label: "science", displayName: "Science", sortOrder: 2)
  context.insert(tech)
  context.insert(gaming)
  context.insert(science)

  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple company news.", sortOrder: 0,
    folderLabel: "technology")
  let ps5 = Category(
    label: "ps5", displayName: "PlayStation 5", categoryDescription: "PS5 news.", sortOrder: 0,
    folderLabel: "gaming")
  let space = Category(
    label: "space", displayName: "Space", categoryDescription: "Space science.", sortOrder: 0,
    folderLabel: "science")
  context.insert(apple)
  context.insert(ps5)
  context.insert(space)
  try? context.save()

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
    .frame(width: 480, height: 500)
}
