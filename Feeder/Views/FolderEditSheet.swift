import SwiftData
import SwiftUI

struct FolderEditSheet: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(\.dismiss)
  private var dismiss
  @Query(sort: \Folder.sortOrder)
  private var allFolders: [Folder]

  let folder: Folder?

  @State
  private var name: String = ""
  @State
  private var showDeleteConfirmation = false

  private var isNew: Bool { folder == nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      form
      Divider()
      footer
    }
    .frame(width: 400)
    .frame(minHeight: 200)
    .onAppear {
      if let folder {
        name = folder.displayName
      }
    }
    .alert("Delete Folder?", isPresented: $showDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        performDelete()
      }
    } message: {
      Text("Categories in this folder will be moved to root level.")
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(isNew ? "New Folder" : "Edit Folder")
        .font(FontTheme.headline)
      Spacer()
    }
    .padding()
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Name")
        .font(FontTheme.caption)
        .foregroundStyle(.secondary)
      TextField("Folder name", text: $name)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: FontTheme.bodySize))
    }
    .padding()
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      if !isNew {
        Button("Delete Folder", role: .destructive) {
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

  // MARK: - Actions

  private func save() {
    guard let writer = syncEngine.writer else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)

    if let folder {
      let label = folder.label
      Task {
        try? await writer.updateFolderFields(label: label, displayName: trimmedName)
        dismiss()
      }
    } else {
      let label = makeUniqueLabel(from: trimmedName, fallbackPrefix: "folder")
      Task {
        try? await writer.addFolder(label: label, displayName: trimmedName, sortOrder: allFolders.count)
        dismiss()
      }
    }
  }

  private func performDelete() {
    guard let writer = syncEngine.writer, let folder else { return }
    let label = folder.label
    Task {
      try? await writer.deleteFolder(label: label)
      dismiss()
    }
  }
}

// MARK: - Preview

#Preview("New Folder") {
  folderEditNewPreview()
}

@MainActor
private func folderEditNewPreview() -> some View {
  let config = ModelConfiguration(isStoredInMemoryOnly: true)
  guard
    let container = try? ModelContainer(
      for: Entry.self, Feed.self, Category.self, Folder.self,
      configurations: config
    )
  else {
    fatalError("Preview ModelContainer failed")
  }

  return FolderEditSheet(folder: nil)
    .environment(SyncEngine())
    .modelContainer(container)
}
