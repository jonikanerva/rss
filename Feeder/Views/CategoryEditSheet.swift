import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "CategoryEditSheet")

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
  /// — zero orphans skip the sheet entirely (HIG: don't interrupt the user
  /// when there's nothing to confirm), positive counts open the reassign
  /// sheet with a dropdown target-category picker.
  @State
  private var orphanCount: Int?
  /// Drives the reassign `.sheet` visibility. Distinct from the empty-category
  /// fast path: when `orphanCount == 0` we flip straight to `performDelete()`
  /// without showing any sheet.
  @State
  private var reassignSheetIsPresented = false
  /// Picker selection bound to the destructive sheet's `.menu`-style
  /// `Picker`. Initialised to the system `uncategorizedLabel` when the
  /// sheet opens so a calm default — "moves to Uncategorized" — is always
  /// the resting state; the user has to actively choose another category.
  @State
  private var reassignTarget: String = uncategorizedLabel
  /// Debounces the destructive button against double-Return: while the
  /// reassign-and-delete writer Task is in flight, the button is disabled
  /// so a second `.defaultAction` keyboard fire cannot fire two
  /// `removeCategoryAndReassignArticles` calls back-to-back. The first
  /// call already enforces atomicity inside `DataWriter`, but a second
  /// call after the source category has been deleted would surface a
  /// confusing `.sourceMissing` error to the user.
  @State
  private var isReassigning = false
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
    // Sheet-based destructive confirmation. The prior `.confirmationDialog`
    // collapsed past ~10 buttons (HIG-documented truncation threshold) and
    // forced the user to scan a vertical wall of "Move to <category>"
    // buttons. The replacement is a single dropdown `Picker` plus two
    // buttons — cancel (escape) and destructive confirm (return) — which
    // stays calm even at 20+ categories. HIG → Alerts → Best practices:
    // "use a sheet for confirmations that need a non-trivial choice".
    .sheet(isPresented: $reassignSheetIsPresented) {
      CategoryRecategorizeSheet(
        sourceDisplayName: category?.displayName ?? "",
        orphanCount: orphanCount ?? 0,
        targets: reassignTargets,
        selectedTarget: $reassignTarget,
        isReassigning: isReassigning,
        onCancel: { reassignSheetIsPresented = false },
        onConfirm: { performReassignAndDelete(targetLabel: reassignTarget) }
      )
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

  // MARK: - Reassign sheet inputs

  /// Categories the user can pick as the move target. Excludes the source
  /// category (can't move articles into the category being removed); the
  /// system `uncategorized` row stays included because that's exactly the
  /// intended fallback per `docs/stack.md` § Persistence shape
  /// (`DefaultCategoryData` seeds it as a system category, and
  /// `applyClassification` already uses it as the validation fallback).
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
  /// - count > 0 ⇒ open the reassign sheet with a target picker.
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
        // Seed the picker to the system fallback so the resting state is
        // always "moves to Uncategorized" — the user never has to scroll
        // through targets just to accept the safe default.
        reassignTarget = uncategorizedLabel
        reassignSheetIsPresented = true
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
  /// typed `CategoryReassignError` — there is no partial state. `isReassigning`
  /// flips to true for the duration of the writer Task so the destructive
  /// button is disabled while the call is in flight, preventing a double-Return
  /// from firing the writer twice.
  private func performReassignAndDelete(targetLabel: String) {
    guard let writer = syncEngine.writer, let category else { return }
    let sourceLabel = category.label
    isReassigning = true
    Task {
      defer { isReassigning = false }
      do {
        _ = try await writer.removeCategoryAndReassignArticles(
          sourceLabel, to: targetLabel
        )
        reassignSheetIsPresented = false
        dismiss()
      } catch let error as CategoryReassignError {
        // Typed cases have localized descriptions tailored to the user
        // (`docs/stack.md` § Logging & privacy — category labels are public
        // taxonomy strings, safe to surface). Dismiss the sheet first so the
        // alert is the only modal on screen — stacking a `.alert` on top of
        // a `.sheet` is undefined on macOS.
        reassignSheetIsPresented = false
        errorMessage = error.localizedDescription
      } catch {
        // Generic SwiftData / NSError-style text would leak implementation
        // detail. Log the underlying error privately and show a friendly
        // fallback instead.
        logger.error(
          "Category reassign failed: \(error.localizedDescription, privacy: .private)"
        )
        reassignSheetIsPresented = false
        errorMessage = "Couldn't remove category. Please try again."
      }
    }
  }
}

// MARK: - Recategorize sheet

/// Destructive confirmation sheet shown when the user removes a category that
/// still owns articles. The user chooses a move-target via a `.menu`-style
/// `Picker`, then confirms with the destructive button (default action,
/// Return) or cancels (Escape). Designed to replace the prior
/// `.confirmationDialog` which scaled poorly past ~10 categories — Apple's
/// alert truncation kicks in there and the user is left scrolling buttons.
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
    footnote: "After confirm: generic fallback — \u{201C}Couldn't remove category. Please try again.\u{201D}"
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

/// Empty / zero-orphans state: the destructive path skips the recategorize
/// sheet entirely because there is nothing to move. The preview renders the
/// edit sheet so the destructive footer button is visible; the production
/// flow short-circuits to `performDelete()` without ever presenting the
/// recategorize sheet.
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
    .environment(SyncEngine())
    .environment(AppFontSettings())
    .modelContainer(container)
}

// MARK: - Preview host + fixtures

/// Preview host that mounts `CategoryRecategorizeSheet` directly — no
/// `@Query` wiring required because the sheet receives its target list as a
/// plain `[Category]` parameter. Drives `selectedTarget` via local `@State`
/// so the user can interact with the picker inside the preview canvas.
/// Footnote annotates which state the preview is exercising.
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

/// Preview-only fixtures for the recategorize sheet's target list. Keeps
/// the preview matrix free of repeated `Category(...)` boilerplate and
/// ensures the four target-count scenarios (typical / single / large /
/// expanded) share a consistent shape.
@MainActor
private enum PreviewCategoryFixtures {
  /// Returns a single shared `Category` instance for the system fallback,
  /// so every preview slots the same "Uncategorized" target at the head
  /// of its list. `isSystem` mirrors `DefaultCategoryData`'s seed.
  private static func uncategorized() -> Category {
    let cat = Category(
      label: uncategorizedLabel, displayName: "Uncategorized",
      categoryDescription: "Use only when no other category clearly matches.",
      sortOrder: Int.max, isSystem: true
    )
    return cat
  }

  /// 8 targets including the system fallback — the calm baseline the
  /// HIG-documented `.confirmationDialog` truncation threshold sits just
  /// above. Picker shown collapsed/expanded covers two of the matrix slots.
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

  /// Single-target edge case: only the system `Uncategorized` remains
  /// after filtering out the source category. The sheet must still show
  /// — the destructive confirmation is the load-bearing UX, not the
  /// choice (HIG → Alerts: disclosure > silence).
  static func singleTargetSet() -> [Category] {
    [uncategorized()]
  }

  /// `count` targets including the system fallback. Used by the large-N
  /// preview to prove `.menu` Picker style stays usable where
  /// `.confirmationDialog` would have collapsed past Apple's button
  /// threshold.
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
