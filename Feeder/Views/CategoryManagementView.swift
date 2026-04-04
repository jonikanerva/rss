import SwiftData
import SwiftUI

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

  @State
  private var editingCategory: Category?
  @State
  private var editingFolder: Folder?
  @State
  private var showNewCategorySheet = false
  @State
  private var showNewFolderSheet = false
  @State
  private var dropTargetLabel: String?
  @State
  private var dropRootPosition: Int?
  @State
  private var dropChildPosition: String?

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
      isDropTarget: dropTargetLabel == folder.label,
      onEdit: { editingFolder = folder }
    )
    .dropDestination(for: String.self) { labels, _ in
      guard let draggedLabel = labels.first else { return false }
      handleMoveToFolder(draggedLabel, folderLabel: folder.label)
      return true
    } isTargeted: { targeted in
      dropTargetLabel = targeted ? folder.label : (dropTargetLabel == folder.label ? nil : dropTargetLabel)
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

  // MARK: - Root drop zone (for moving categories out of folders to root)

  @ViewBuilder
  private func rootDropZone(position: Int) -> some View {
    let isTargeted = dropRootPosition == position
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 8)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleMoveToRoot(draggedLabel, at: position)
        return true
      } isTargeted: { targeted in
        dropRootPosition = targeted ? position : (dropRootPosition == position ? nil : dropRootPosition)
      }
  }

  // MARK: - Child drop zone (within a folder)

  @ViewBuilder
  private func childDropZone(folderLabel: String, position: Int) -> some View {
    let key = "\(folderLabel):\(position)"
    let isTargeted = dropChildPosition == key
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 6)
      .padding(.leading, 20)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleInsertInFolder(draggedLabel, folderLabel: folderLabel, at: position)
        return true
      } isTargeted: { targeted in
        dropChildPosition = targeted ? key : (dropChildPosition == key ? nil : dropChildPosition)
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

  private var rootCategories: [Category] { allCategories.atRoot }

  // MARK: - Drop handlers

  private func handleMoveToFolder(_ draggedLabel: String, folderLabel: String) {
    guard let writer = syncEngine.writer else { return }
    if draggedLabel == uncategorizedLabel { return }

    let childCount = allCategories.inFolder(folderLabel).count
    Task {
      try? await writer.batchUpdateCategoryFolderAndSortOrders(
        folderChanges: [(draggedLabel, folderLabel, childCount)],
        sortOrderUpdates: []
      )
    }
  }

  private func handleInsertInFolder(_ draggedLabel: String, folderLabel: String, at position: Int) {
    guard let writer = syncEngine.writer else { return }
    if draggedLabel == uncategorizedLabel { return }

    var children = allCategories.inFolder(folderLabel).map(\.label)
    children.removeAll { $0 == draggedLabel }
    let insertAt = min(position, children.count)
    children.insert(draggedLabel, at: insertAt)

    let sortOrderUpdates = children.enumerated().map { (index, label) in
      (label: label, sortOrder: index)
    }

    let draggedCategory = allCategories.first { $0.label == draggedLabel }
    let needsMove = draggedCategory?.folderLabel != folderLabel
    var folderChanges: [(label: String, folderLabel: String?, sortOrder: Int)] = []
    if needsMove {
      folderChanges.append((draggedLabel, folderLabel, insertAt))
    }

    Task {
      try? await writer.batchUpdateCategoryFolderAndSortOrders(
        folderChanges: folderChanges, sortOrderUpdates: sortOrderUpdates
      )
    }
  }

  private func handleMoveToRoot(_ draggedLabel: String, at position: Int) {
    guard let writer = syncEngine.writer else { return }
    if draggedLabel == uncategorizedLabel { return }

    var rootLabels = rootCategories.map(\.label)
    rootLabels.removeAll { $0 == draggedLabel }
    let insertAt = min(position, rootLabels.count)
    rootLabels.insert(draggedLabel, at: insertAt)

    let sortOrderUpdates = rootLabels.enumerated().map { (index, label) in
      (label: label, sortOrder: index)
    }

    let draggedCategory = allCategories.first { $0.label == draggedLabel }
    var folderChanges: [(label: String, folderLabel: String?, sortOrder: Int)] = []
    if draggedCategory?.folderLabel != nil {
      folderChanges.append((draggedLabel, nil, insertAt))
    }

    Task {
      try? await writer.batchUpdateCategoryFolderAndSortOrders(
        folderChanges: folderChanges, sortOrderUpdates: sortOrderUpdates
      )
    }
  }
}

// MARK: - Compact Row

private struct CategoryCompactRow: View {
  let displayName: String
  let descriptionPreview: String
  let depth: Int
  let isSystem: Bool
  let isDropTarget: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(displayName)
          .font(FontTheme.bodyMedium)
        Text(descriptionPreview.prefix(50) + (descriptionPreview.count > 50 ? "…" : ""))
          .font(FontTheme.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if !isSystem {
        Button("Edit") {
          onEdit()
        }
      }
    }
    .padding(.leading, CGFloat(depth) * 20)
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
    )
  }
}

private struct FolderCompactRow: View {
  let displayName: String
  let isDropTarget: Bool
  let onEdit: () -> Void

  var body: some View {
    HStack {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      Text(displayName)
        .font(FontTheme.bodyMedium)
      Spacer()
      Button("Edit") {
        onEdit()
      }
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
    )
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
