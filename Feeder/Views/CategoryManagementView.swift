import SwiftData
import SwiftUI

// MARK: - Focus tracking for inline editing

enum CategoryFocusedField: Hashable {
    case name(String)
    case description(String)
}

// MARK: - Inline Category Editor (embedded in Settings Categories tab)

struct CategoryManagementView: View {
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Environment(SyncEngine.self) private var syncEngine

    @Query(filter: #Predicate<Category> { $0.isTopLevel == true }, sort: \Category.sortOrder)
    private var topLevelCategories: [Category]

    @Query private var allCategories: [Category]

    @FocusState private var focusedField: CategoryFocusedField?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if topLevelCategories.isEmpty && allCategories.isEmpty {
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
            Button {
                addCategory()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add top-level category")
            .accessibilityIdentifier("categories.add")
        }
        .padding()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Categories", systemImage: "tag")
        } description: {
            Text("Add categories to classify your articles.")
        } actions: {
            Button("Add Default Categories") {
                seedDefaultCategories()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("categories.seedDefaults")
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Category list with hierarchy

    private var categoryList: some View {
        List {
            ForEach(topLevelCategories) { parent in
                CategoryRowEditor(
                    category: parent,
                    focusedField: $focusedField,
                    allTopLevel: topLevelCategories,
                    onDelete: { deleteCategory(parent) }
                )
                ChildCategoryManagementItems(
                    parentLabel: parent.label,
                    focusedField: $focusedField,
                    allTopLevel: topLevelCategories
                )
            }
            .onMove { indices, destination in
                moveTopLevel(from: indices, to: destination)
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
                .disabled(topLevelCategories.isEmpty && allCategories.isEmpty)
                .help("Re-run classification on all articles with current categories")
                .accessibilityIdentifier("categories.reclassify")
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func addCategory() {
        guard let writer = syncEngine.writer else { return }
        let label = "new_category_\(Int.random(in: 1000...9999))"
        Task {
            try? await writer.addCategory(
                label: label,
                displayName: "New Category",
                description: "Describe what articles belong in this category.",
                sortOrder: topLevelCategories.count
            )
        }
        focusedField = .name(label)
    }

    private func deleteCategory(_ category: Category) {
        guard let writer = syncEngine.writer else { return }
        let label = category.label
        Task {
            try? await writer.deleteCategory(label: label)
        }
    }

    private func moveTopLevel(from source: IndexSet, to destination: Int) {
        guard let writer = syncEngine.writer else { return }
        var ordered = topLevelCategories.sorted { $0.sortOrder < $1.sortOrder }
        ordered.move(fromOffsets: source, toOffset: destination)
        let updates = ordered.enumerated().map { (index, cat) in (label: cat.label, sortOrder: index) }
        Task {
            try? await writer.updateCategorySortOrders(updates)
        }
    }

    // MARK: - Seed defaults (hierarchical)

    private func seedDefaultCategories() {
        guard let writer = syncEngine.writer else { return }
        let defaults: [(label: String, displayName: String, description: String, sortOrder: Int, parentLabel: String?)] = [
            (
                "technology", "Technology",
                "A broad category for all news about technology companies, products, platforms, and innovations. This includes news about Apple, Tesla, AI companies, and any other tech company. Use alongside more specific categories when applicable.",
                0, nil
            ),
            (
                "gaming", "Gaming",
                "Game releases, game reviews, gameplay content, game announcements, and game-specific news. For business news about the gaming industry (layoffs, acquisitions, financial results), use 'gaming_industry' instead.",
                1, nil
            ),
            (
                "world", "World",
                "Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries.",
                2, nil
            ),
            ("other", "Other", "Use only when no other category clearly matches. Never combine with another category.", 3, nil),
            (
                "apple", "Apple",
                "All news about Apple company, its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series), services, and innovations.",
                0, "technology"
            ),
            ("tesla", "Tesla", "All news related to Tesla company, its vehicles, energy products, and innovations.", 1, "technology"),
            (
                "ai", "AI",
                "Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies like OpenAI or Anthropic, and applied generative AI. Do not apply when a product merely uses AI as a feature.",
                2, "technology"
            ),
            (
                "home_automation", "Home Automation",
                "Smart home devices, home automation platforms (Google Home, Apple HomeKit, Amazon Alexa), Matter protocol, and related IoT technologies for the home.",
                3, "technology"
            ),
            (
                "gaming_industry", "Gaming Industry",
                "Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes. Use this instead of 'gaming' when the article is about the business side rather than games themselves.",
                0, "gaming"
            ),
            (
                "playstation_5", "PlayStation 5",
                "All news specifically about PlayStation 5 games, hardware, and ecosystem. Exclude mobile gaming, PC gaming, and other console news, which should be categorized under 'gaming'.",
                1, "gaming"
            ),
        ]
        Task {
            try? await writer.seedDefaultCategories(defaults)
        }
    }
}

// MARK: - Child Category Items (dynamic @Query filtered by parent in SQLite)

/// Renders child categories under a parent using a @Query predicate.
struct ChildCategoryManagementItems: View {
    @Query private var children: [Category]
    @Environment(SyncEngine.self) private var syncEngine

    var focusedField: FocusState<CategoryFocusedField?>.Binding
    let allTopLevel: [Category]

    init(parentLabel: String, focusedField: FocusState<CategoryFocusedField?>.Binding, allTopLevel: [Category]) {
        _children = Query(
            filter: #Predicate<Category> { $0.parentLabel == parentLabel },
            sort: \Category.sortOrder
        )
        self.focusedField = focusedField
        self.allTopLevel = allTopLevel
    }

    var body: some View {
        ForEach(children) { child in
            CategoryRowEditor(
                category: child,
                focusedField: focusedField,
                allTopLevel: allTopLevel,
                onDelete: { deleteChild(child) }
            )
            .padding(.leading, 16)
        }
        .onMove { indices, destination in
            moveChildren(from: indices, to: destination)
        }
    }

    private func deleteChild(_ child: Category) {
        guard let writer = syncEngine.writer else { return }
        let label = child.label
        Task { try? await writer.deleteCategory(label: label) }
    }

    private func moveChildren(from source: IndexSet, to destination: Int) {
        guard let writer = syncEngine.writer else { return }
        var kids = Array(children)
        kids.move(fromOffsets: source, toOffset: destination)
        let updates = kids.enumerated().map { (index, cat) in (label: cat.label, sortOrder: index) }
        Task { try? await writer.updateCategorySortOrders(updates) }
    }
}

// MARK: - Inline Row Editor

struct CategoryRowEditor: View {
    let category: Category
    var focusedField: FocusState<CategoryFocusedField?>.Binding
    let allTopLevel: [Category]
    let onDelete: () -> Void

    @Environment(SyncEngine.self) private var syncEngine
    @State private var editedName: String = ""
    @State private var editedDescription: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Name", text: $editedName)
                .textFieldStyle(.plain)
                .font(FontTheme.bodyMedium)
                .focused(focusedField, equals: .name(category.label))
                .onSubmit { commitEdits() }

            TextField("Description", text: $editedDescription, axis: .vertical)
                .textFieldStyle(.plain)
                .font(FontTheme.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2...5)
                .focused(focusedField, equals: .description(category.label))
                .onSubmit { commitEdits() }
        }
        .padding(.vertical, 2)
        .contextMenu { contextMenuItems }
        .onAppear {
            editedName = category.displayName
            editedDescription = category.categoryDescription
        }
        .onChange(of: category.displayName) { _, newValue in
            editedName = newValue
        }
        .onChange(of: category.categoryDescription) { _, newValue in
            editedDescription = newValue
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if category.isTopLevel {
            let others = allTopLevel.filter { $0.label != category.label }
            if !others.isEmpty {
                Menu("Make Subcategory of...") {
                    ForEach(others) { parent in
                        Button(parent.displayName) {
                            makeSubcategory(of: parent)
                        }
                    }
                }
            }
        } else {
            Button("Make Top-Level") {
                makeTopLevel()
            }
            let others = allTopLevel.filter { $0.label != category.parentLabel }
            if !others.isEmpty {
                Menu("Move to...") {
                    ForEach(others) { parent in
                        Button(parent.displayName) {
                            makeSubcategory(of: parent)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            onDelete()
        }
    }

    private func makeSubcategory(of parent: Category) {
        guard let writer = syncEngine.writer else { return }
        let label = category.label
        let parentLabel = parent.label
        Task {
            try? await writer.updateCategoryHierarchy(
                label: label, parentLabel: parentLabel,
                depth: 1, isTopLevel: false, sortOrder: 0
            )
        }
    }

    private func makeTopLevel() {
        guard let writer = syncEngine.writer else { return }
        let label = category.label
        let sortOrder = allTopLevel.count
        Task {
            try? await writer.updateCategoryHierarchy(
                label: label, parentLabel: nil,
                depth: 0, isTopLevel: true, sortOrder: sortOrder
            )
        }
    }

    private func commitEdits() {
        guard let writer = syncEngine.writer else { return }
        let label = category.label
        let name = editedName
        let desc = editedDescription
        Task {
            try? await writer.updateCategoryFields(label: label, displayName: name, description: desc)
        }
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
    let container = try! ModelContainer(
        for: Entry.self, Feed.self, Category.self,
        configurations: config
    )
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
    let container = try! ModelContainer(
        for: Entry.self, Feed.self, Category.self,
        configurations: config
    )

    return CategoryManagementView()
        .environment(ClassificationEngine())
        .environment(SyncEngine())
        .modelContainer(container)
        .frame(width: 600, height: 500)
}
