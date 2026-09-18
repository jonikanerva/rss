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

  /// Root-level categories, filtered at SQLite level and never in the render
  /// path.
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
  /// Which folder row is selected. The selection activates that row's
  /// context-menu shortcuts, so a folder reorders without the mouse.
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

  /// The categories live in a `List`, not the surrounding `Form`, because
  /// `.onMove` is synthesized only inside a `List`. Each folder reorders its own
  /// children in place, a cross-folder move goes through the row context menu,
  /// and the system category is move-disabled so it never drifts.
  ///
  /// The selection binding activates the folder context-menu shortcuts, which
  /// keeps the reorder keyboard-operable beside the drag affordance.
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

  /// Folder header row, tagged so the list selection drives the context-menu
  /// shortcuts, and labelled so VoiceOver announces the row's position.
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

  /// The four move buttons. The directional moves carry shortcuts, so they
  /// surface in the row's context menu and stay discoverable
  /// (`STACK.md § 11 → Keyboard`). The to-top and to-bottom moves carry none,
  /// matching the platform convention.
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

  /// Per-row view. The context menu attaches only for a non-system category:
  /// gating the menu body alone leaves an empty menu on the system row.
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

  /// The move-to-folder submenu. The HIG asks for an unavailable destination to
  /// be hidden rather than disabled.
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

  /// Apply an `.onMove` index shuffle: rebuild the label order locally, then
  /// ship only the `[String]` order across the actor boundary.
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

  /// The folder-list sibling of the category reorder, shipping the folder label
  /// order instead.
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

  /// Keyboard and context-menu folder move. It keeps the selection on the moved
  /// row, so further keyboard moves chain.
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

  /// Ship a label order across the actor boundary. The writer owns the logging.
  private func persistFolderOrder(_ orderedLabels: [String]) {
    guard let writer = syncEngine.writer else { return }
    Task {
      try? await writer.reorderFolders(orderedLabels: orderedLabels)
    }
  }

  /// Announce the new position after a programmatic move. It must read the
  /// locally computed label order: the queried array refreshes only after the
  /// write round-trips through the store.
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

  /// Move a category between folders, or to root, from the context menu. The new
  /// sort order appends past the target's existing peers, as the edit sheet does.
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

/// Exercises the reorder states: enough folders that the directional moves are
/// enabled or disabled depending on which row is selected.
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
