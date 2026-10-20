import SwiftData
import SwiftUI

struct CategoryEditSheet: View {
  @Environment(ClassificationEngine.self)
  private var classificationEngine
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
  /// Entries carrying this category, or `nil` while the count fetch is in
  /// flight. Resolved off MainActor before the destructive flow opens: a zero
  /// count skips the sheet, because the HIG says not to interrupt the user with
  /// nothing to confirm.
  @State
  private var orphanCount: Int?
  /// Drives the reassign sheet's visibility. With no orphans the flow goes
  /// straight to the delete and shows no sheet at all.
  @State
  private var reassignSheetIsPresented = false
  /// Selection bound to the destructive sheet's picker. It opens on the system
  /// fallback, so the resting state is always the safe move and the user must
  /// choose any other target.
  @State
  private var reassignTarget: String = uncategorizedLabel
  /// Owns the one writer call that the sheet waits for. A running call
  /// disables every submit button, so a second Return cannot submit twice.
  @State
  private var operation: TaxonomyOperation

  init(category: Category?, folders: [Folder], operation: TaxonomyOperation = TaxonomyOperation()) {
    self.category = category
    self.folders = folders
    self._operation = State(initialValue: operation)
  }

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
    // A sheet, not a `confirmationDialog`: the dialog truncates past the
    // HIG-documented button threshold, and the HIG asks for a sheet whenever a
    // confirmation needs a non-trivial choice. One picker plus cancel and
    // confirm stays calm at any category count.
    .sheet(isPresented: $reassignSheetIsPresented) {
      CategoryRecategorizeSheet(
        sourceDisplayName: category?.displayName ?? "",
        orphanCount: orphanCount ?? 0,
        targets: reassignTargets,
        selectedTarget: $reassignTarget,
        isReassigning: operation.isRunning,
        onCancel: { reassignSheetIsPresented = false },
        onConfirm: { performReassignAndDelete(targetLabel: reassignTarget) }
      )
    }
    .onDisappear { operation.cancel() }
    .taxonomyFailureAlert(operation)
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

  // MARK: - Reassign sheet inputs

  /// Categories the user can pick as the move target. The source category is
  /// excluded, because articles cannot move into the category being removed.
  /// The system fallback stays included: it is the intended target.
  private var reassignTargets: [Category] {
    guard let category else { return [] }
    return allCategories.filter { $0.label != category.label }
  }

  // MARK: - Helpers

  private func categoriesInTarget(_ folderLabel: String?) -> [Category] {
    if let folderLabel {
      return allCategories.inFolder(folderLabel)
    }
    return allCategories.atRoot
  }

  // MARK: - Actions

  /// The edit path runs two writes. When the folder move fails after the field
  /// update, the fields stay saved and the sheet stays open; a retry repeats
  /// both writes, and the field update is idempotent.
  private func save() {
    guard let writer = syncEngine.writer else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    let trimmedDesc = description.trimmingCharacters(in: .whitespaces)
    let folder = selectedFolderLabel
    let sortOrder = categoriesInTarget(folder).count

    if let category {
      let label = category.label
      let movesFolder = category.folderLabel != folder
      operation.submit(
        failure: .save("category"),
        work: {
          try await writer.updateCategoryFields(
            label: label, displayName: trimmedName, description: trimmedDesc
          )
          if movesFolder {
            try await writer.moveCategoryToFolder(label: label, folderLabel: folder, sortOrder: sortOrder)
          }
        },
        onSuccess: { finishDefinitionChange(writer: writer) }
      )
    } else {
      let label = makeUniqueLabel(from: trimmedName, fallbackPrefix: "category")
      operation.submit(
        failure: .create("category"),
        work: {
          try await writer.addCategory(
            label: label, displayName: trimmedName,
            description: trimmedDesc, sortOrder: sortOrder,
            folderLabel: folder
          )
        },
        onSuccess: { finishDefinitionChange(writer: writer) }
      )
    }
  }

  /// Branch the delete flow on the orphan count: no orphans deletes at once,
  /// because there is nothing to confirm, and any orphans open the reassign
  /// sheet. A failed count stops the flow: it is no evidence of zero orphans.
  private func beginDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    let label = category.label
    operation.submit(
      failure: .countArticles,
      work: { try await writer.countEntries(primaryCategoryLabel: label) },
      onSuccess: { count in
        orphanCount = count
        if count == 0 {
          performDelete()
        } else {
          // Seed the picker to the system fallback, so accepting the safe
          // default never means scrolling through the targets.
          reassignTarget = uncategorizedLabel
          reassignSheetIsPresented = true
        }
      }
    )
  }

  /// Delete path for a category with no orphaned entries: no article needs a
  /// new home, so the writer call is a plain delete.
  private func performDelete() {
    guard let writer = syncEngine.writer, let category else { return }
    let label = category.label
    operation.submit(
      failure: .remove("category"),
      work: { try await writer.deleteCategory(label: label) },
      onSuccess: { finishDefinitionChange(writer: writer) }
    )
  }

  /// Run the atomic reassign-and-delete on the writer: it either moves every
  /// orphan and deletes the source, or fails with a typed error. There is no
  /// partial state.
  private func performReassignAndDelete(targetLabel: String) {
    guard let writer = syncEngine.writer, let category else { return }
    let sourceLabel = category.label
    operation.submit(
      failure: { error in
        guard let error = error as? CategoryReassignError else { return .remove("category") }
        return TaxonomyEditFailure(title: "Couldn't remove category", message: error.localizedDescription)
      },
      work: {
        _ = try await writer.removeCategoryAndReassignArticles(sourceLabel, to: targetLabel)
      },
      // Close the reassign sheet before the alert shows: stacking an alert on a
      // sheet is undefined on macOS.
      onFailure: { reassignSheetIsPresented = false },
      onSuccess: {
        reassignSheetIsPresented = false
        finishDefinitionChange(writer: writer)
      }
    )
  }

  /// Call only after a committed write that can change the category
  /// definitions. The restart lets a fix end a blocked drain at once
  /// (`STACK.md → Cloud classification`).
  private func finishDefinitionChange(writer: DataWriter) {
    classificationEngine.configurationChanged(writer: writer)
    dismiss()
  }
}

// MARK: - Recategorize sheet

/// Destructive confirmation shown when the user removes a category that still
/// owns articles. The user picks a move target, then confirms with the
/// destructive default action or cancels with Escape. A sheet rather than a
/// dialog, which truncates past the HIG button threshold.
@MainActor
private struct CategoryRecategorizeSheet: View {
  @Environment(AppFontSettings.self)
  private var fontSettings

  let sourceDisplayName: String
  let orphanCount: Int
  let targets: [Category]
  @Binding
  var selectedTarget: String
  let isReassigning: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remove \u{201C}\(sourceDisplayName)\u{201D}?")
        .font(fontSettings.headline)

      Text(
        "All \(orphanCount) \(orphanCount == 1 ? "article" : "articles") will be moved to the category you choose below. \u{201C}\(sourceDisplayName)\u{201D} will then be removed. This can't be undone."
      )
      .font(fontSettings.body)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Text("Move articles to:")
          .font(fontSettings.body)
        Picker("Move articles to", selection: $selectedTarget) {
          ForEach(targets, id: \.label) { target in
            Text(target.displayName).tag(target.label)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityIdentifier("category.recategorize.target")
      }

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("category.recategorize.cancel")

        Button("Remove Category", role: .destructive) {
          onConfirm()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isReassigning)
        .accessibilityIdentifier("category.recategorize.confirm")
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}

// MARK: - Previews

#Preview("Edit Existing Category") {
  categoryEditExistingPreview()
}

#Preview("New Category") {
  categoryEditNewPreview()
}

#Preview("Edit Category — Saving") {
  categoryEditExistingPreview(operation: TaxonomyOperation(phase: .running))
}

#Preview("Edit Category — Save failed") {
  categoryEditExistingPreview(operation: TaxonomyOperation(phase: .failed(.save("category"))))
}

#Preview("Edit Category — Article count failed") {
  categoryEditExistingPreview(operation: TaxonomyOperation(phase: .failed(.countArticles)))
}

#Preview("Recategorize Sheet — Typical (collapsed)") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 12,
    targets: PreviewCategoryFixtures.typicalSet(),
    isReassigning: false,
    initialSelection: uncategorizedLabel,
    footnote: "Typical: 8 categories, Picker collapsed showing the safe default."
  )
}

#Preview("Recategorize Sheet — Typical (expanded)") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 12,
    targets: PreviewCategoryFixtures.typicalSet(),
    isReassigning: false,
    initialSelection: "world_news",
    footnote: "Typical expanded: same data, Picker showing a non-default selection."
  )
}

#Preview("Recategorize Sheet — Single target") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 3,
    targets: PreviewCategoryFixtures.singleTargetSet(),
    isReassigning: false,
    initialSelection: uncategorizedLabel,
    footnote: "Edge case: only Uncategorized remains. Sheet still shows — disclosure > silence."
  )
}

#Preview("Recategorize Sheet — Large N") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 47,
    targets: PreviewCategoryFixtures.largeSet(count: 22),
    isReassigning: false,
    initialSelection: uncategorizedLabel,
    footnote: "22 targets — proves .menu Picker stays calm where .confirmationDialog would truncate."
  )
}

#Preview("Recategorize — Empty (zero orphans path)") {
  categoryEditReassignEmptyPreview()
}

#Preview("Recategorize Sheet — Error (targetMissing)") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 5,
    targets: PreviewCategoryFixtures.typicalSet(),
    isReassigning: false,
    initialSelection: uncategorizedLabel,
    footnote: "After confirm: error alert path — \(CategoryReassignError.targetMissing.localizedDescription)"
  )
}

#Preview("Recategorize Sheet — Error (generic)") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 5,
    targets: PreviewCategoryFixtures.typicalSet(),
    isReassigning: false,
    initialSelection: uncategorizedLabel,
    footnote: "After confirm: generic fallback — \(TaxonomyEditFailure.remove("category").message)"
  )
}

#Preview("Recategorize Sheet — In-flight") {
  RecategorizeSheetPreviewHost(
    sourceDisplayName: "Apple",
    orphanCount: 12,
    targets: PreviewCategoryFixtures.typicalSet(),
    isReassigning: true,
    initialSelection: uncategorizedLabel,
    footnote: "Writer Task in flight — destructive button disabled to debounce double-Return."
  )
}

@MainActor
private func categoryEditExistingPreview(operation: TaxonomyOperation = TaxonomyOperation()) -> some View {
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

  return CategoryEditSheet(category: apple, folders: [techFolder], operation: operation)
    .environment(ClassificationEngine())
    .environment(SyncEngine.preview())
    .environment(AppFontSettings())
    .modelContainer(container)
}

@MainActor
private func categoryEditNewPreview() -> some View {
  let container = PreviewSupport.makeContainer()

  return CategoryEditSheet(category: nil, folders: [])
    .environment(ClassificationEngine())
    .environment(SyncEngine.preview())
    .environment(AppFontSettings())
    .modelContainer(container)
}

/// The zero-orphan state, where the destructive path skips the recategorize
/// sheet because there is nothing to move. The preview renders the edit sheet,
/// so the destructive footer button is visible.
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

  return CategoryEditSheet(category: world, folders: [])
    .overlay(alignment: .bottom) {
      Text("Zero orphans: delete proceeds without prompting; no recategorize sheet shown.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(6)
    }
    .environment(ClassificationEngine())
    .environment(SyncEngine.preview())
    .environment(AppFontSettings())
    .modelContainer(container)
}

// MARK: - Preview host + fixtures

/// Preview host that mounts the recategorize sheet directly: it takes its
/// target list as a plain array, so no query wiring is needed, and local state
/// drives the picker so the canvas stays interactive.
@MainActor
private struct RecategorizeSheetPreviewHost: View {
  let sourceDisplayName: String
  let orphanCount: Int
  let targets: [Category]
  let isReassigning: Bool
  let initialSelection: String
  let footnote: String

  @State
  private var selection: String

  init(
    sourceDisplayName: String,
    orphanCount: Int,
    targets: [Category],
    isReassigning: Bool,
    initialSelection: String,
    footnote: String
  ) {
    self.sourceDisplayName = sourceDisplayName
    self.orphanCount = orphanCount
    self.targets = targets
    self.isReassigning = isReassigning
    self.initialSelection = initialSelection
    self.footnote = footnote
    self._selection = State(initialValue: initialSelection)
  }

  var body: some View {
    VStack(spacing: 8) {
      CategoryRecategorizeSheet(
        sourceDisplayName: sourceDisplayName,
        orphanCount: orphanCount,
        targets: targets,
        selectedTarget: $selection,
        isReassigning: isReassigning,
        onCancel: {},
        onConfirm: {}
      )
      Text(footnote)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
    }
    .environment(AppFontSettings())
    .modelContainer(PreviewSupport.makeContainer())
  }
}

/// Preview-only fixtures for the recategorize sheet's target list, so every
/// target-count scenario shares one shape.
@MainActor
private enum PreviewCategoryFixtures {
  /// The system fallback target, so every preview puts the same row at the head
  /// of its list. Its `isSystem` flag mirrors the seeded data.
  private static func uncategorized() -> Category {
    let cat = Category(
      label: uncategorizedLabel, displayName: "Uncategorized",
      categoryDescription: "Use only when no other category clearly matches.",
      sortOrder: Int.max, isSystem: true
    )
    return cat
  }

  /// The calm baseline, just below the HIG-documented dialog truncation
  /// threshold. Shown collapsed and expanded, it covers two matrix slots.
  static func typicalSet() -> [Category] {
    [
      uncategorized(),
      Category(
        label: "ai", displayName: "AI",
        categoryDescription: "AI news.", sortOrder: 0
      ),
      Category(
        label: "world_news", displayName: "World News",
        categoryDescription: "World affairs.", sortOrder: 1
      ),
      Category(
        label: "science", displayName: "Science",
        categoryDescription: "Science research.", sortOrder: 2
      ),
      Category(
        label: "design", displayName: "Design",
        categoryDescription: "Design news.", sortOrder: 3
      ),
      Category(
        label: "swift", displayName: "Swift",
        categoryDescription: "Swift language.", sortOrder: 4
      ),
      Category(
        label: "business", displayName: "Business",
        categoryDescription: "Business news.", sortOrder: 5
      ),
      Category(
        label: "culture", displayName: "Culture",
        categoryDescription: "Culture and arts.", sortOrder: 6
      ),
    ]
  }

  /// The edge case where only the system fallback remains after the source is
  /// filtered out. The sheet must still show: the confirmation is the
  /// load-bearing part, not the choice.
  static func singleTargetSet() -> [Category] {
    [uncategorized()]
  }

  /// `count` targets including the system fallback, for the large-N preview
  /// that exercises the picker above the dialog button threshold.
  static func largeSet(count: Int) -> [Category] {
    let extras = (0..<max(0, count - 1)).map { i in
      Category(
        label: "preview_\(i)", displayName: "Category \(i + 1)",
        categoryDescription: "Preview-only.", sortOrder: i
      )
    }
    return [uncategorized()] + extras
  }
}
