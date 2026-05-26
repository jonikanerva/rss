import SwiftData
import SwiftUI

struct CategoryEditSheet: View {
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(AppFontSettings.self)
  private var fontSettings
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
  /// Number of entries currently carrying `primaryCategory == category.label`.
  /// `nil` while the count fetch is in flight or hasn't been kicked off yet.
  /// Resolved off-MainActor on `DataWriter` before the destructive flow opens
  /// — zero orphans skip the dialog entirely (HIG: don't interrupt the user
  /// when there's nothing to confirm), positive counts open the reassign
  /// confirmation dialog with a target-category picker.
  @State
  private var orphanCount: Int?
  /// Drives `.confirmationDialog` visibility for the reassign-and-delete flow.
  /// Distinct from the empty-category fast path: when `orphanCount == 0` we
  /// flip straight to `performDelete()` without showing any dialog.
  @State
  private var showReassignDialog = false
  /// Surfaces `CategoryReassignError` cases (target missing mid-flight,
  /// system-category guard tripped, etc.) to the user.
  @State
  private var errorMessage: String?

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
    // SwiftUI's `confirmationDialog` is the macOS-native primitive for an
    // uncommon destructive action that cannot be undone — HIG → Alerts → Best
    // practices. The dialog renders as a native sheet with a destructive title
    // and one button per move-target category, plus Cancel. Return triggers
    // the first non-cancel button, Escape cancels — full keyboard nav with no
    // custom plumbing.
    .confirmationDialog(
      reassignDialogTitle,
      isPresented: $showReassignDialog,
      titleVisibility: .visible
    ) {
      ForEach(reassignTargets, id: \.label) { target in
        Button("Move to \(target.displayName)", role: .destructive) {
          performReassignAndDelete(targetLabel: target.label)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(reassignDialogMessage)
    }
    .alert(
      "Couldn't remove category",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      ),
      actions: {
        Button("OK", role: .cancel) { errorMessage = nil }
      },
      message: {
        Text(errorMessage ?? "")
      }
    )
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(isNew ? "New Category" : "Edit Category")
        .font(fontSettings.headline)
      Spacer()
    }
    .padding()
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Name")
          .font(fontSettings.caption)
          .foregroundStyle(.secondary)
        TextField("Category name", text: $name)
          .textFieldStyle(.roundedBorder)
          .font(fontSettings.body)
          .disabled(category?.isSystem ?? false)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Folder")
          .font(fontSettings.caption)
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
          .font(fontSettings.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: $description)
          .font(fontSettings.body)
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
          beginDelete()
        }
        .accessibilityIdentifier("category.delete")
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

  // MARK: - Reassign dialog inputs

  /// Categories the user can pick as the move target. Excludes the source
  /// category (can't move articles into the category being removed) and the
  /// system `uncategorized` row is included — that's exactly the intended
  /// fallback per `docs/stack.md` § Persistence shape (`DefaultCategoryData`
  /// already seeds it as a system category, and `applyClassification` already
  /// uses it as the validation fallback).
  private var reassignTargets: [Category] {
    guard let category else { return [] }
    return allCategories.filter { $0.label != category.label }
  }

  /// Localised dialog title with the orphan count and source category name —
  /// the user knows exactly how many articles are about to move before they
  /// commit.
  private var reassignDialogTitle: String {
    let count = orphanCount ?? 0
    let articleWord = count == 1 ? "article" : "articles"
    let displayName = category?.displayName ?? ""
    return "Move \(count) \(articleWord) from \u{201C}\(displayName)\u{201D}?"
  }

  /// Supporting message explains the destructive nature explicitly. HIG → Alerts:
  /// describe the consequence so the user doesn't have to infer it.
  private var reassignDialogMessage: String {
    let displayName = category?.displayName ?? ""
    return
      "Choose a category to move the articles into. \u{201C}\(displayName)\u{201D} will be removed afterwards. This can't be undone."
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
      let label = makeUniqueLabel(from: trimmedName, fallbackPrefix: "category")
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

  /// Branch the delete flow on the current orphan count:
  /// - count == 0 ⇒ delete immediately (no user prompt — nothing to confirm).
  /// - count > 0 ⇒ open the reassign confirmation dialog with a target picker.
  /// The count fetch runs off-MainActor on `DataWriter` so the MainActor never
  /// iterates `@Query` rows looking for orphans.
  private func beginDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    let label = category.label
    Task {
      let count = (try? await writer.countEntries(primaryCategoryLabel: label)) ?? 0
      orphanCount = count
      if count == 0 {
        performDelete()
      } else {
        showReassignDialog = true
      }
    }
  }

  /// Fast-path delete used when there are zero orphaned entries assigned to
  /// the category — no articles need a new home, so the writer call collapses
  /// to a single `deleteCategory`.
  private func performDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    let label = category.label
    Task {
      try? await writer.deleteCategory(label: label)
      dismiss()
    }
  }

  /// Run the atomic reassign-and-delete on the writer. The writer either moves
  /// every orphan to the picked target and deletes the source, or fails with a
  /// typed `CategoryReassignError` — there is no partial state.
  private func performReassignAndDelete(targetLabel: String) {
    guard let writer = syncEngine.writer, let category else { return }
    let sourceLabel = category.label
    Task {
      do {
        _ = try await writer.removeCategoryAndReassignArticles(
          sourceLabel, to: targetLabel
        )
        dismiss()
      } catch let error as CategoryReassignError {
        errorMessage = error.localizedDescription
      } catch {
        errorMessage = error.localizedDescription
      }
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

#Preview("Reassign Dialog — Success") {
  categoryEditReassignSuccessPreview()
}

#Preview("Reassign Dialog — Empty (No Orphans)") {
  categoryEditReassignEmptyPreview()
}

#Preview("Reassign Dialog — Error") {
  categoryEditReassignErrorPreview()
}

@MainActor
private func categoryEditExistingPreview() -> some View {
  let container = PreviewSupport.makeContainer()
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
    .environment(AppFontSettings())
    .modelContainer(container)
}

@MainActor
private func categoryEditNewPreview() -> some View {
  let container = PreviewSupport.makeContainer()

  return CategoryEditSheet(category: nil, folders: [])
    .environment(SyncEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
}

/// Renders the edit sheet with the reassign confirmation dialog opened against
/// a category that owns three articles. Exercises the "Success" UI state from
/// `docs/definition-of-done.md` § UI states — Delete Category → dialog appears
/// → user picks a target.
@MainActor
private func categoryEditReassignSuccessPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let techFolder = Folder(label: "technology", displayName: "Technology", sortOrder: 0)
  context.insert(techFolder)

  let apple = Category(
    label: "apple", displayName: "Apple",
    categoryDescription: "Apple Inc. news.",
    sortOrder: 0, folderLabel: "technology"
  )
  let ai = Category(
    label: "ai", displayName: "AI",
    categoryDescription: "AI news.",
    sortOrder: 1, folderLabel: "technology"
  )
  let world = Category(
    label: "world_news", displayName: "World News",
    categoryDescription: "World affairs.",
    sortOrder: 0
  )
  context.insert(apple)
  context.insert(ai)
  context.insert(world)

  // Seed three classified entries assigned to `apple` so the reassign dialog
  // surfaces a meaningful "3 articles" count.
  for i in 1...3 {
    let entry = Entry(
      feedbinEntryID: i, title: "Apple Story \(i)", author: nil,
      url: "https://example.com/\(i)", content: "Content \(i)", summary: nil,
      extractedContentURL: nil,
      publishedAt: .now.addingTimeInterval(-Double(i) * 600), createdAt: .now
    )
    entry.isClassified = true
    entry.primaryCategory = "apple"
    entry.primaryFolder = "technology"
    context.insert(entry)
  }
  try? context.save()

  return CategoryEditSheetPreviewHarness(
    category: apple, folders: [techFolder], initialOrphanCount: 3, openReassignDialog: true
  )
  .environment(SyncEngine())
  .environment(AppFontSettings())
  .modelContainer(container)
}

/// Empty state for the recategorize flow — a category with zero orphans
/// should skip the dialog entirely and delete straight through. The preview
/// renders the edit sheet so the destructive footer button is visible without
/// the dialog overlay; the real flow short-circuits to `performDelete()`.
@MainActor
private func categoryEditReassignEmptyPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let world = Category(
    label: "world_news", displayName: "World News",
    categoryDescription: "World affairs — no orphaned entries.",
    sortOrder: 0
  )
  context.insert(world)
  try? context.save()

  return CategoryEditSheetPreviewHarness(
    category: world, folders: [], initialOrphanCount: 0, openReassignDialog: false
  )
  .environment(SyncEngine())
  .environment(AppFontSettings())
  .modelContainer(container)
}

/// Error state — surfaces the `CategoryReassignError.targetMissing`
/// localized description through the same alert binding the production view
/// uses. Demonstrates how a mid-flight failure (target deleted concurrently
/// in another sheet) is reported to the user.
@MainActor
private func categoryEditReassignErrorPreview() -> some View {
  let container = PreviewSupport.makeContainer()
  let context = container.mainContext

  let apple = Category(
    label: "apple", displayName: "Apple",
    categoryDescription: "Apple Inc. news.",
    sortOrder: 0
  )
  context.insert(apple)
  try? context.save()

  return CategoryEditSheetPreviewHarness(
    category: apple, folders: [],
    initialOrphanCount: 2, openReassignDialog: false,
    initialErrorMessage: CategoryReassignError.targetMissing.localizedDescription
  )
  .environment(SyncEngine())
  .environment(AppFontSettings())
  .modelContainer(container)
}

/// Preview-only harness that mounts the production `CategoryEditSheet` and
/// pre-opens the reassign dialog / error alert so the canvas exercises those
/// states without driving them through a `Task` that would race the preview
/// renderer.
@MainActor
private struct CategoryEditSheetPreviewHarness: View {
  let category: Category?
  let folders: [Folder]
  let initialOrphanCount: Int
  let openReassignDialog: Bool
  var initialErrorMessage: String? = nil

  var body: some View {
    CategoryEditSheet(category: category, folders: folders)
      .overlay(alignment: .bottom) {
        Text(
          openReassignDialog
            ? "Preview: tap \u{201C}Delete Category\u{201D} to open the reassign dialog ( \(initialOrphanCount) articles)"
            : initialErrorMessage.map { "Preview: error alert shown — \($0)" }
              ?? "Preview: empty state — delete proceeds without prompting"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(6)
      }
  }
}
