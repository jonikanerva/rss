import SwiftData
import SwiftUI

// MARK: - Category Management View

struct CategoryManagementView: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(SyncEngine.self)
  private var syncEngine

  @Query(filter: #Predicate<Category> { $0.isTopLevel == true }, sort: \Category.sortOrder)
  private var topLevelCategories: [Category]

  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]

  @State
  private var editingCategory: Category?
  @State
  private var showNewCategorySheet = false
  @State
  private var dropTargetLabel: String?
  @State
  private var dropAsTopLevelPosition: Int?
  @State
  private var dropChildPosition: String?

  var body: some View {
    Form {
      Section {
        actionButtons
      }

      if allCategories.isEmpty {
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

  // MARK: - Category list (drag-and-drop hierarchy)

  private var categoryList: some View {
    VStack(spacing: 0) {
      topLevelDropZone(position: 0)

      ForEach(Array(topLevelCategories.enumerated()), id: \.element.persistentModelID) {
        topIndex,
        parent in
        parentCategorySection(parent: parent, topIndex: topIndex)
      }
    }
  }

  @ViewBuilder
  private func parentCategorySection(parent: Category, topIndex: Int) -> some View {
    CategoryCompactRow(
      label: parent.label,
      displayName: parent.displayName,
      descriptionPreview: parent.categoryDescription,
      depth: 0,
      isDropTarget: dropTargetLabel == parent.label,
      onEdit: { editingCategory = parent }
    )
    .draggable(parent.label)
    .dropDestination(for: String.self) { labels, _ in
      guard let draggedLabel = labels.first, draggedLabel != parent.label else { return false }
      handleMakeChild(draggedLabel, of: parent.label)
      return true
    } isTargeted: { targeted in
      dropTargetLabel = targeted ? parent.label : (dropTargetLabel == parent.label ? nil : dropTargetLabel)
    }

    let children = childCategories(of: parent.label)
    if !children.isEmpty {
      childDropZone(parentLabel: parent.label, position: 0)
    }
    ForEach(Array(children.enumerated()), id: \.element.persistentModelID) { childIndex, child in
      CategoryCompactRow(
        label: child.label,
        displayName: child.displayName,
        descriptionPreview: child.categoryDescription,
        depth: 1,
        isDropTarget: false,
        onEdit: { editingCategory = child }
      )
      .draggable(child.label)
      childDropZone(parentLabel: parent.label, position: childIndex + 1)
    }

    topLevelDropZone(position: topIndex + 1)
  }

  // MARK: - Top-level drop zone

  @ViewBuilder
  private func topLevelDropZone(position: Int) -> some View {
    let isTargeted = dropAsTopLevelPosition == position
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 8)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleMakeTopLevel(draggedLabel, at: position)
        return true
      } isTargeted: { targeted in
        dropAsTopLevelPosition = targeted ? position : (dropAsTopLevelPosition == position ? nil : dropAsTopLevelPosition)
      }
  }

  // MARK: - Child drop zone

  @ViewBuilder
  private func childDropZone(parentLabel: String, position: Int) -> some View {
    let key = "\(parentLabel):\(position)"
    let isTargeted = dropChildPosition == key
    Rectangle()
      .fill(isTargeted ? Color.accentColor : Color.clear)
      .frame(height: 6)
      .padding(.leading, 20)
      .dropDestination(for: String.self) { labels, _ in
        guard let draggedLabel = labels.first else { return false }
        handleInsertChild(draggedLabel, in: parentLabel, at: position)
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
      Button("New Category...") {
        showNewCategorySheet = true
      }
      .accessibilityIdentifier("categories.add")
    }
    .sheet(isPresented: $showNewCategorySheet) {
      CategoryEditSheet(category: nil, allTopLevel: topLevelCategories)
    }
    .sheet(item: $editingCategory) { category in
      CategoryEditSheet(category: category, allTopLevel: topLevelCategories)
    }
  }

  // MARK: - Child lookup (small category count, acceptable in-memory filter)

  private func childCategories(of parentLabel: String) -> [Category] {
    allCategories
      .filter { $0.parentLabel == parentLabel }
      .sorted { $0.sortOrder < $1.sortOrder }
  }

  // MARK: - Drop handlers

  private func handleMakeChild(_ draggedLabel: String, of parentLabel: String) {
    guard let writer = syncEngine.writer else { return }

    let targetParent = allCategories.first { $0.label == parentLabel }
    if targetParent?.parentLabel == draggedLabel { return }
    if draggedLabel == parentLabel { return }

    let childCount = childCategories(of: parentLabel).count
    let orphans = childCategories(of: draggedLabel)

    var hierarchyChanges: [(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int)] = [
      (draggedLabel, parentLabel, 1, false, childCount)
    ]
    for (index, orphan) in orphans.enumerated() {
      hierarchyChanges.append((orphan.label, nil, 0, true, topLevelCategories.count + index))
    }

    Task {
      try? await writer.batchUpdateCategoryHierarchyAndSortOrders(
        hierarchyChanges: hierarchyChanges, sortOrderUpdates: []
      )
    }
  }

  private func handleInsertChild(_ draggedLabel: String, in parentLabel: String, at position: Int) {
    guard let writer = syncEngine.writer else { return }
    let draggedCategory = allCategories.first { $0.label == draggedLabel }
    let needsReparent = draggedCategory?.parentLabel != parentLabel

    let targetParent = allCategories.first { $0.label == parentLabel }
    if targetParent?.parentLabel == draggedLabel { return }

    var children = childCategories(of: parentLabel).map(\.label)
    children.removeAll { $0 == draggedLabel }
    let insertAt = min(position, children.count)
    children.insert(draggedLabel, at: insertAt)

    let sortOrderUpdates = children.enumerated().map { (index, label) in
      (label: label, sortOrder: index)
    }

    var hierarchyChanges: [(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int)] = []
    if needsReparent {
      hierarchyChanges.append((draggedLabel, parentLabel, 1, false, insertAt))
      for (index, orphan) in childCategories(of: draggedLabel).enumerated() {
        hierarchyChanges.append((orphan.label, nil, 0, true, topLevelCategories.count + index))
      }
    }

    Task {
      try? await writer.batchUpdateCategoryHierarchyAndSortOrders(
        hierarchyChanges: hierarchyChanges, sortOrderUpdates: sortOrderUpdates
      )
    }
  }

  private func handleMakeTopLevel(_ draggedLabel: String, at position: Int) {
    guard let writer = syncEngine.writer else { return }
    var ordered = topLevelCategories.map(\.label)
    ordered.removeAll { $0 == draggedLabel }
    let insertAt = min(position, ordered.count)
    ordered.insert(draggedLabel, at: insertAt)

    let sortOrderUpdates = ordered.enumerated().map { (index, label) in
      (label: label, sortOrder: index)
    }

    let draggedCategory = allCategories.first { $0.label == draggedLabel }
    var hierarchyChanges: [(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int)] = []
    if draggedCategory?.isTopLevel == false {
      hierarchyChanges.append((draggedLabel, nil, 0, true, insertAt))
    }

    Task {
      try? await writer.batchUpdateCategoryHierarchyAndSortOrders(
        hierarchyChanges: hierarchyChanges, sortOrderUpdates: sortOrderUpdates
      )
    }
  }
}

// MARK: - Compact Row

private struct CategoryCompactRow: View {
  let label: String
  let displayName: String
  let descriptionPreview: String
  let depth: Int
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
      Button("Edit") {
        onEdit()
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

// MARK: - Preview

#Preview("Category Management - Hierarchical") {
  categoryManagementHierarchicalPreview()
}

#Preview("Category Management - Empty") {
  categoryManagementEmptyPreview()
}

@MainActor
private func categoryManagementHierarchicalPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }
  let context = container.mainContext

  let technology = Category(
    label: "technology", displayName: "Technology", categoryDescription: "Technology coverage.", sortOrder: 0)
  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple company news.", sortOrder: 0,
    parentLabel: "technology")
  let ai = Category(
    label: "ai", displayName: "AI", categoryDescription: "AI and ML news.", sortOrder: 1, parentLabel: "technology")
  let world = Category(label: "world", displayName: "World", categoryDescription: "Global policy news.", sortOrder: 1)

  context.insert(technology)
  context.insert(apple)
  context.insert(ai)
  context.insert(world)
  try? context.save()

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .modelContainer(container)
    .frame(width: 600, height: 500)
}

@MainActor
private func categoryManagementEmptyPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }

  return CategoryManagementView()
    .environment(ClassificationEngine())
    .environment(SyncEngine())
    .modelContainer(container)
    .frame(width: 600, height: 500)
}
