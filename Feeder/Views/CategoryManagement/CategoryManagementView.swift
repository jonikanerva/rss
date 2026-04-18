import SwiftData
import SwiftUI

// MARK: - Drop target state

/// Unified drop hover state. Replaces three parallel optionals
/// (folder label / root position / child position) with a single enum so the
/// "what is the drag currently over?" question has one answer.
private enum DropTarget: Hashable {
  case folder(String)
  case rootPosition(Int)
  case childPosition(folder: String, position: Int)
}

// MARK: - Category Management View

struct CategoryManagementView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine

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
  @State
  private var currentDropTarget: DropTarget?

  var body: some View {
    Form {
      Section {
        actionButtons
      }

      if allCategories.isEmpty && folders.isEmpty {
        Section("Categories") {
          ContentUnavailableView {
            Label("No Categories", systemImage: "tag")
          } description: {
            Text("Create categories to classify your articles.")
          }
        }
      } else {
        Section("Categories") {
          categoryList
        }
      }
    }
    .formStyle(.grouped)
  }

  // MARK: - Category list (drag-and-drop with folders)

  private var categoryList: some View {
    VStack(spacing: 0) {
      // Folders with their categories
      ForEach(folders) { folder in
        folderSection(folder: folder)
      }

      // Root-level categories (no folder)
      rootDropZone(position: 0)
      ForEach(Array(rootCategories.enumerated()), id: \.element.persistentModelID) { index, category in
        CategoryCompactRow(
          displayName: category.displayName,
          descriptionPreview: category.categoryDescription,
          depth: 0,
          isSystem: category.isSystem,
          isDropTarget: false,
          onEdit: { editingCategory = category }
        )
        .draggable(category.label)
        rootDropZone(position: index + 1)
      }
    }
  }

  @ViewBuilder
  private func folderSection(folder: Folder) -> some View {
    FolderCompactRow(
      displayName: folder.displayName,
      isDropTarget: currentDropTarget == .folder(folder.label),
      onEdit: { editingFolder = folder }
    )
    .dropDestination(for: String.self) { labels, _ in
      guard let draggedLabel = labels.first else { return false }
      handleMoveToFolder(draggedLabel, folderLabel: folder.label)
      return true
    } isTargeted: { targeted in
      updateHover(targeted ? .folder(folder.label) : nil, matching: .folder(folder.label))
    }

    let children = allCategories.inFolder(folder.label)
    if !children.isEmpty {
      childDropZone(folderLabel: folder.label, position: 0)
    }
    ForEach(Array(children.enumerated()), id: \.element.persistentModelID) { childIndex, child in
      CategoryCompactRow(
        displayName: child.displayName,
        descriptionPreview: child.categoryDescription,
        depth: 1,
        isSystem: child.isSystem,
        isDropTarget: false,
        onEdit: { editingCategory = child }
      )
      .draggable(child.label)
      childDropZone(folderLabel: folder.label, position: childIndex + 1)
    }
  }

  // MARK: - Drop zones

  @ViewBuilder
  private func rootDropZone(position: Int) -> some View {
    let target = DropTarget.rootPosition(position)
    let isTargeted = currentDropTarget == target
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 8)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleMoveToRoot(draggedLabel, at: position)
        return true
      } isTargeted: { targeted in
        updateHover(targeted ? target : nil, matching: target)
      }
  }

  @ViewBuilder
  private func childDropZone(folderLabel: String, position: Int) -> some View {
    let target = DropTarget.childPosition(folder: folderLabel, position: position)
    let isTargeted = currentDropTarget == target
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 6)
      .padding(.leading, 20)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleInsertInFolder(draggedLabel, folderLabel: folderLabel, at: position)
        return true
      } isTargeted: { targeted in
        updateHover(targeted ? target : nil, matching: target)
      }
  }

  // MARK: - Footer

  private var actionButtons: some View {
    HStack {
      if classificationEngine.isClassifying {
        ProgressView()
          .scaleEffect(0.7)
        Text(classificationEngine.progress)
          .font(FontTheme.caption)
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

  // MARK: - Lookups

  private func snapshotsInFolder(_ folderLabel: String) -> [CategorySnapshot] {
    allCategories.inFolder(folderLabel).map { CategorySnapshot(label: $0.label) }
  }

  private func rootSnapshots() -> [CategorySnapshot] {
    rootCategories.map { CategorySnapshot(label: $0.label) }
  }

  private func draggedCategoryFolder(label: String) -> String? {
    allCategories.first { $0.label == label }?.folderLabel
  }

  // MARK: - Drop handlers

  private func handleMoveToFolder(_ draggedLabel: String, folderLabel: String) {
    guard let writer = syncEngine.writer,
      let plan = planMoveToFolder(
        dragged: draggedLabel,
        targetFolder: folderLabel,
        existingInFolder: snapshotsInFolder(folderLabel)
      )
    else { return }
    apply(plan, using: writer)
  }

  private func handleInsertInFolder(_ draggedLabel: String, folderLabel: String, at position: Int) {
    guard let writer = syncEngine.writer,
      let plan = planInsertInFolder(
        dragged: draggedLabel,
        draggedCurrentFolder: draggedCategoryFolder(label: draggedLabel),
        targetFolder: folderLabel,
        position: position,
        existingInFolder: snapshotsInFolder(folderLabel)
      )
    else { return }
    apply(plan, using: writer)
  }

  private func handleMoveToRoot(_ draggedLabel: String, at position: Int) {
    guard let writer = syncEngine.writer,
      let plan = planMoveToRoot(
        dragged: draggedLabel,
        draggedCurrentFolder: draggedCategoryFolder(label: draggedLabel),
        position: position,
        existingAtRoot: rootSnapshots()
      )
    else { return }
    apply(plan, using: writer)
  }

  private func apply(_ plan: CategoryDropPlan, using writer: DataWriter) {
    let folderChanges = plan.folderChanges.map { change in
      (label: change.label, folderLabel: change.folderLabel, sortOrder: change.sortOrder)
    }
    let sortOrderUpdates = plan.sortOrderUpdates.map { update in
      (label: update.label, sortOrder: update.sortOrder)
    }
    Task {
      try? await writer.batchUpdateCategoryFolderAndSortOrders(
        folderChanges: folderChanges, sortOrderUpdates: sortOrderUpdates
      )
    }
  }

  // MARK: - Hover helpers

  /// Update `currentDropTarget` only when the incoming change actually affects
  /// the requested target. Matches the "latch a single target at a time"
  /// behavior the old three-optional layout had.
  private func updateHover(_ newValue: DropTarget?, matching target: DropTarget) {
    if let value = newValue {
      currentDropTarget = value
    } else if currentDropTarget == target {
      currentDropTarget = nil
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

@MainActor
private func categoryManagementPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self, Folder.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }
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
    .modelContainer(container)
    .frame(width: 480, height: 500)
}

@MainActor
private func categoryManagementEmptyPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self, Folder.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .modelContainer(container)
    .frame(width: 480, height: 500)
}
