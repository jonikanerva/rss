import SwiftData
import SwiftUI

struct FolderEditSheet: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(\.dismiss)
  private var dismiss
  @Query(sort: \Folder.sortOrder)
  private var allFolders: [Folder]

  let folder: Folder?

  @State
  private var name: String = ""
  @State
  private var showDeleteConfirmation = false
  /// Owns the one writer call that the sheet waits for. A running call
  /// disables every submit button, so a second Return cannot submit twice.
  @State
  private var operation: TaxonomyOperation

  init(folder: Folder?, operation: TaxonomyOperation = TaxonomyOperation()) {
    self.folder = folder
    self._operation = State(initialValue: operation)
  }

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
    .onDisappear { operation.cancel() }
    .taxonomyFailureAlert(operation)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(isNew ? "New Folder" : "Edit Folder")
        .font(fontSettings.headline)
      Spacer()
    }
    .padding()
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Name")
        .font(fontSettings.caption)
        .foregroundStyle(.secondary)
      TextField("Folder name", text: $name)
        .textFieldStyle(.roundedBorder)
        .font(fontSettings.body)
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
        .disabled(operation.isRunning)
      }
      Spacer()
      if operation.isRunning {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Saving")
      }
      Button("Cancel") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      Button(isNew ? "Create" : "Save") {
        save()
      }
      .keyboardShortcut(.defaultAction)
      .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || operation.isRunning)
    }
    .padding()
  }

  // MARK: - Actions

  private func save() {
    guard let writer = syncEngine.writer else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)

    if let folder {
      let label = folder.label
      operation.submit(
        failure: .save("folder"),
        work: { try await writer.updateFolderFields(label: label, displayName: trimmedName) },
        onSuccess: { dismiss() }
      )
    } else {
      let label = makeUniqueLabel(from: trimmedName, fallbackPrefix: "folder")
      let sortOrder = allFolders.count
      operation.submit(
        failure: .create("folder"),
        work: { try await writer.addFolder(label: label, displayName: trimmedName, sortOrder: sortOrder) },
        onSuccess: { dismiss() }
      )
    }
  }

  private func performDelete() {
    guard let writer = syncEngine.writer, let folder else { return }
    let label = folder.label
    operation.submit(
      failure: .remove("folder"),
      work: { try await writer.deleteFolder(label: label) },
      onSuccess: { dismiss() }
    )
  }
}

// MARK: - Preview

#Preview("New Folder") {
  folderEditNewPreview()
}

#Preview("New Folder — Creating") {
  folderEditNewPreview(operation: TaxonomyOperation(phase: .running))
}

#Preview("New Folder — Create failed") {
  folderEditNewPreview(operation: TaxonomyOperation(phase: .failed(.create("folder"))))
}

@MainActor
private func folderEditNewPreview(operation: TaxonomyOperation = TaxonomyOperation()) -> some View {
  let container = PreviewSupport.makeContainer()

  return FolderEditSheet(folder: nil, operation: operation)
    .environment(SyncEngine.preview())
    .environment(AppFontSettings())
    .modelContainer(container)
}
