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
  @ViewBuilder
  private var categoryList: some View {
    List {
      ForEach(folders) { folder in
        folderSection(folder: folder)
      }
      rootSection
    }
  }

  @ViewBuilder
  private func folderSection(folder: Folder) -> some View {
    let children = allCategories.inFolder(folder.label)
    Section {
      FolderCompactRow(displayName: folder.displayName, onEdit: { editingFolder = folder })
      ForEach(children, id: \.persistentModelID) { child in
        categoryRow(child, depth: 1)
      }
      .onMove { indices, newOffset in
        reorder(children: children, inFolder: folder.label, source: indices, destination: newOffset)
      }
    }
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
    .modelContainer(container)
    .frame(width: 480, height: 500)
}

@MainActor
private func categoryManagementEmptyPreview() -> some View {
  let container = PreviewSupport.makeContainer()

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .modelContainer(container)
    .frame(width: 480, height: 500)
}
