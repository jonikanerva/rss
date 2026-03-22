import SwiftData
import SwiftUI

struct CategoryEditSheet: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(\.dismiss)
  private var dismiss

  let category: Category?
  let allTopLevel: [Category]

  @State
  private var name: String = ""
  @State
  private var description: String = ""
  @State
  private var showDeleteConfirmation = false
  @State
  private var childNamesToDelete: [String] = []

  private var isNew: Bool { category == nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      form
      Divider()
      footer
    }
    .frame(width: 500)
    .frame(minHeight: 350)
    .onAppear {
      if let category {
        name = category.displayName
        description = category.categoryDescription
      }
    }
    .alert("Delete Category?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        performDelete()
      }
    } message: {
      if childNamesToDelete.isEmpty {
        Text("Are you sure you want to delete \"\(category?.displayName ?? "")\"?")
      } else {
        Text(
          "This will also delete subcategories: \(childNamesToDelete.joined(separator: ", ")). Are you sure?"
        )
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(isNew ? "New Category" : "Edit Category")
        .font(FontTheme.headline)
      Spacer()
    }
    .padding()
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Name")
          .font(FontTheme.caption)
          .foregroundStyle(.secondary)
        TextField("Category name", text: $name)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: FontTheme.bodySize))
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Description")
          .font(FontTheme.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: $description)
          .font(.system(size: FontTheme.bodySize))
          .frame(minHeight: 80, maxHeight: 160)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(.quaternary, lineWidth: 1)
          )
      }
    }
    .padding()
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      if !isNew {
        Button("Delete Category", role: .destructive) {
          prepareDelete()
        }
      }
      Spacer()
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button(isNew ? "Create" : "Save") {
        save()
      }
      .keyboardShortcut(.defaultAction)
      .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding()
  }

  // MARK: - Actions

  private func save() {
    guard let writer = syncEngine.writer else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let trimmedDesc = description.trimmingCharacters(in: .whitespaces)

    if let category {
      let label = category.label
      Task {
        try? await writer.updateCategoryFields(
          label: label, displayName: trimmedName, description: trimmedDesc
        )
        dismiss()
      }
    } else {
      let sanitized = trimmedName.lowercased()
        .replacingOccurrences(of: " ", with: "_")
        .filter { $0.isLetter || $0.isNumber || $0 == "_" }
      let label = (sanitized.isEmpty ? "category" : sanitized)
        .appending("_\(Int.random(in: 1000...9999))")
      let sortOrder = allTopLevel.count
      Task {
        try? await writer.addCategory(
          label: label, displayName: trimmedName,
          description: trimmedDesc, sortOrder: sortOrder
        )
        dismiss()
      }
    }
  }

  private func prepareDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    if category.isTopLevel {
      let label = category.label
      Task {
        let names = (try? await writer.childCategoryNames(for: label)) ?? []
        childNamesToDelete = names
        showDeleteConfirmation = true
      }
    } else {
      childNamesToDelete = []
      showDeleteConfirmation = true
    }
  }

  private func performDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    let label = category.label
    Task {
      try? await writer.deleteCategory(label: label)
      dismiss()
    }
  }
}

// MARK: - Previews

#Preview("Edit Existing Category") {
  categoryEditExistingPreview()
}

#Preview("New Category") {
  categoryEditNewPreview()
}

@MainActor
private func categoryEditExistingPreview() -> some View {
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
    label: "technology", displayName: "Technology",
    categoryDescription: "A broad category for all news about technology companies, products, platforms, and innovations.",
    sortOrder: 0
  )
  let apple = Category(
    label: "apple", displayName: "Apple",
    categoryDescription: "All news about Apple company and products.",
    sortOrder: 0, parentLabel: "technology"
  )
  context.insert(technology)
  context.insert(apple)
  try? context.save()

  return CategoryEditSheet(category: technology, allTopLevel: [technology])
    .environment(SyncEngine())
    .modelContainer(container)
}

@MainActor
private func categoryEditNewPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }

  return CategoryEditSheet(category: nil, allTopLevel: [])
    .environment(SyncEngine())
    .modelContainer(container)
}
