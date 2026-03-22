import SwiftData
import SwiftUI

// MARK: - Flat row model for hierarchical display

private struct FlatCategoryRow: Identifiable {
  let id: PersistentIdentifier
  let label: String
  let displayName: String
  let descriptionPreview: String
  let depth: Int
  let isTopLevel: Bool
}

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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      if allCategories.isEmpty {
        emptyState
      } else {
        categoryList
      }

      Divider()
      footer
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Categories")
        .font(FontTheme.headline)
      Spacer()
    }
    .padding()
  }

  // MARK: - Empty state

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Categories", systemImage: "tag")
    } description: {
      Text("Create categories to classify your articles.")
    }
    .frame(maxHeight: .infinity)
  }

  // MARK: - Category list (flat hierarchy with indentation)

  private var categoryList: some View {
    List {
      ForEach(flattenedRows, id: \.id) { row in
        CategoryCompactRow(
          row: row,
          onEdit: {
            editingCategory = allCategories.first { $0.label == row.label }
          }
        )
      }
      .onMove { indices, destination in
        moveCategories(from: indices, to: destination)
      }
    }
    .listStyle(.plain)
  }

  // MARK: - Footer

  private var footer: some View {
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
    .padding()
    .sheet(isPresented: $showNewCategorySheet) {
      CategoryEditSheet(category: nil, allTopLevel: topLevelCategories)
    }
    .sheet(item: $editingCategory) { category in
      CategoryEditSheet(category: category, allTopLevel: topLevelCategories)
    }
  }

  // MARK: - Flatten hierarchy

  private var flattenedRows: [FlatCategoryRow] {
    var rows: [FlatCategoryRow] = []
    for parent in topLevelCategories {
      rows.append(
        FlatCategoryRow(
          id: parent.persistentModelID,
          label: parent.label,
          displayName: parent.displayName,
          descriptionPreview: parent.categoryDescription,
          depth: 0,
          isTopLevel: true
        ))
      let children =
        allCategories
        .filter { $0.parentLabel == parent.label }
        .sorted { $0.sortOrder < $1.sortOrder }
      for child in children {
        rows.append(
          FlatCategoryRow(
            id: child.persistentModelID,
            label: child.label,
            displayName: child.displayName,
            descriptionPreview: child.categoryDescription,
            depth: 1,
            isTopLevel: false
          ))
      }
    }
    return rows
  }

  // MARK: - Reorder

  private func moveCategories(from source: IndexSet, to destination: Int) {
    guard let writer = syncEngine.writer else { return }
    var rows = flattenedRows
    rows.move(fromOffsets: source, toOffset: destination)

    var topLevelOrder = 0
    var childOrders: [String: Int] = [:]
    for row in rows {
      if row.isTopLevel {
        let updates = [(label: row.label, sortOrder: topLevelOrder)]
        topLevelOrder += 1
        Task { try? await writer.updateCategorySortOrders(updates) }
      } else {
        let parentLabel = allCategories.first { $0.label == row.label }?.parentLabel ?? ""
        let key = parentLabel
        let order = childOrders[key, default: 0]
        childOrders[key] = order + 1
        let updates = [(label: row.label, sortOrder: order)]
        Task { try? await writer.updateCategorySortOrders(updates) }
      }
    }
  }
}

// MARK: - Compact Row

private struct CategoryCompactRow: View {
  let row: FlatCategoryRow
  let onEdit: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(row.displayName)
          .font(FontTheme.bodyMedium)
        Text(row.descriptionPreview)
          .font(FontTheme.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
      Button {
        onEdit()
      } label: {
        Image(systemName: "pencil")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Edit category")
    }
    .padding(.leading, CGFloat(row.depth) * 20)
    .padding(.vertical, 2)
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

  let technology = Category(label: "technology", displayName: "Technology", categoryDescription: "Technology coverage.", sortOrder: 0)
  let apple = Category(
    label: "apple", displayName: "Apple", categoryDescription: "Apple company news.", sortOrder: 0, parentLabel: "technology")
  let ai = Category(label: "ai", displayName: "AI", categoryDescription: "AI and ML news.", sortOrder: 1, parentLabel: "technology")
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
