import SwiftData
import SwiftUI

struct CategoryEditSheet: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(\.dismiss)
  private var dismiss
  @Query(sort: \Category.sortOrder)
  private var allCategories: [Category]

  let category: Category?
  let folders: [Folder]

  @State
  private var name: String = ""
  @State
  private var description: String = ""
  @State
  private var selectedFolderLabel: String?
  @State
  private var showDeleteConfirmation = false

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
        selectedFolderLabel = category.folderLabel
      }
    }
    .alert("Delete Category?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        performDelete()
      }
    } message: {
      Text("Are you sure you want to delete \"\(category?.displayName ?? "")\"?")
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
          .disabled(category?.isSystem ?? false)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Folder")
          .font(FontTheme.caption)
          .foregroundStyle(.secondary)
        Picker("Folder", selection: $selectedFolderLabel) {
          Text("None (root level)").tag(String?.none)
          ForEach(folders) { folder in
            Text(folder.displayName).tag(Optional(folder.label))
          }
        }
        .labelsHidden()
        .disabled(category?.isSystem ?? false)
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
      if !isNew && !(category?.isSystem ?? false) {
        Button("Delete Category", role: .destructive) {
          showDeleteConfirmation = true
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

  // MARK: - Helpers

  private func categoriesInTarget(_ folderLabel: String?) -> [Category] {
    if let folderLabel {
      return allCategories.inFolder(folderLabel)
    }
    return allCategories.atRoot
  }

  // MARK: - Actions

  private func save() {
    guard let writer = syncEngine.writer else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let trimmedDesc = description.trimmingCharacters(in: .whitespaces)

    if let category {
      let label = category.label
      let folder = selectedFolderLabel
      Task {
        try? await writer.updateCategoryFields(
          label: label, displayName: trimmedName, description: trimmedDesc
        )
        if category.folderLabel != folder {
          let sortOrder = categoriesInTarget(folder).count
          try? await writer.moveCategoryToFolder(label: label, folderLabel: folder, sortOrder: sortOrder)
        }
        dismiss()
      }
    } else {
      let sanitized = trimmedName.lowercased()
        .replacingOccurrences(of: " ", with: "_")
        .filter { $0.isLetter || $0.isNumber || $0 == "_" }
      let label = (sanitized.isEmpty ? "category" : sanitized)
        .appending("_\(Int.random(in: 1000...9999))")
      let sortOrder = categoriesInTarget(selectedFolderLabel).count
      let folder = selectedFolderLabel
      Task {
        try? await writer.addCategory(
          label: label, displayName: trimmedName,
          description: trimmedDesc, sortOrder: sortOrder,
          folderLabel: folder
        )
        dismiss()
      }
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
    label: "apple", displayName: "Apple",
    categoryDescription: "All news about Apple company and products.",
    sortOrder: 0, folderLabel: "technology"
  )
  context.insert(apple)
  try? context.save()

  return CategoryEditSheet(category: apple, folders: [techFolder])
    .environment(SyncEngine())
    .modelContainer(container)
}

@MainActor
private func categoryEditNewPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self, Folder.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }

  return CategoryEditSheet(category: nil, folders: [])
    .environment(SyncEngine())
    .modelContainer(container)
}
