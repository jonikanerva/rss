import SwiftUI
import SwiftData

struct CategoryManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ClassificationEngine.self) private var classificationEngine
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @State private var isAddingNew = false
    @State private var editingCategory: Category?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Categories")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add category")
                .accessibilityIdentifier("categories.add")
            }
            .padding()

            Divider()

            if categories.isEmpty {
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
            } else {
                List {
                    ForEach(categories) { category in
                        CategoryRowView(category: category) {
                            editingCategory = category
                        }
                    }
                    .onDelete(perform: deleteCategories)
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer with reclassify button
            HStack {
                if classificationEngine.isClassifying {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(classificationEngine.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Reclassify All") {
                        Task {
                            await classificationEngine.reclassifyAll(in: modelContext)
                        }
                    }
                    .disabled(categories.isEmpty)
                    .help("Re-run classification on all articles with current categories")
                    .accessibilityIdentifier("categories.reclassify")
                }
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $isAddingNew) {
            CategoryEditorView(mode: .add) { label, name, description in
                let category = Category(
                    label: label,
                    displayName: name,
                    categoryDescription: description,
                    sortOrder: categories.count
                )
                modelContext.insert(category)
                try? modelContext.save()
            }
        }
        .sheet(item: $editingCategory) { category in
            CategoryEditorView(mode: .edit(category)) { label, name, description in
                category.label = label
                category.displayName = name
                category.categoryDescription = description
                try? modelContext.save()
            }
        }
    }

    private func deleteCategories(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(categories[index])
        }
        try? modelContext.save()
    }

    private func seedDefaultCategories() {
        let defaults: [(String, String, String)] = [
            ("technology", "Technology", "A broad category for all news about technology companies, products, platforms, and innovations. This includes news about Apple, Tesla, AI companies, and any other tech company. Use alongside more specific categories when applicable."),
            ("apple", "Apple", "All news about Apple company, its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series), services, and innovations. Apple news is always also technology news."),
            ("tesla", "Tesla", "All news related to Tesla company, its vehicles, energy products, and innovations. Tesla news is always also technology news."),
            ("ai", "AI", "Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies like OpenAI or Anthropic, and applied generative AI. Do not apply when a product merely uses AI as a feature."),
            ("home_automation", "Home Automation", "Smart home devices, home automation platforms (Google Home, Apple HomeKit, Amazon Alexa), Matter protocol, and related IoT technologies for the home."),
            ("gaming", "Gaming", "Game releases, game reviews, gameplay content, game announcements, and game-specific news. For business news about the gaming industry (layoffs, acquisitions, financial results), use 'gaming_industry' instead."),
            ("gaming_industry", "Gaming Industry", "Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes. Use this instead of 'gaming' when the article is about the business side rather than games themselves."),
            ("playstation_5", "PlayStation 5", "All news specifically about PlayStation 5 games, hardware, and ecosystem. Exclude mobile gaming, PC gaming, and other console news, which should be categorized under 'gaming'."),
            ("world", "World", "Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries."),
            ("other", "Other", "Use only when no other category clearly matches. Never combine with another category."),
        ]

        for (index, (label, name, description)) in defaults.enumerated() {
            let category = Category(label: label, displayName: name, categoryDescription: description, sortOrder: index)
            modelContext.insert(category)
        }
        try? modelContext.save()
    }
}

// MARK: - Category Row

struct CategoryRowView: View {
    let category: Category
    let onEdit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.body)
                Text(category.categoryDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Category Editor

struct CategoryEditorView: View {
    enum Mode: Identifiable {
        case add
        case edit(Category)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let cat): cat.label
            }
        }
    }

    let mode: Mode
    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var displayName: String
    @State private var description: String

    init(mode: Mode, onSave: @escaping (String, String, String) -> Void) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .add:
            _label = State(initialValue: "")
            _displayName = State(initialValue: "")
            _description = State(initialValue: "")
        case .edit(let category):
            _label = State(initialValue: category.label)
            _displayName = State(initialValue: category.displayName)
            _description = State(initialValue: category.categoryDescription)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isEditing ? "Edit Category" : "Add Category")
                .font(.headline)

            Form {
                TextField("Label (e.g., gaming_industry)", text: $label)
                    .disabled(isEditing) // Label is the primary key
                TextField("Display Name", text: $displayName)
                TextEditor(text: $description)
                    .frame(height: 100)
                    .font(.body)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary)
                    )
            }

            Text("The description helps the AI understand what belongs in this category. Be specific about what to include and exclude.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    onSave(label, displayName, description)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(label.isEmpty || displayName.isEmpty || description.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 500, height: 350)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }
}

// MARK: - Preview

#Preview("Category Management - With Data") {
    categoryManagementPreviewWithData()
}

#Preview("Category Management - Empty") {
    categoryManagementPreviewEmpty()
}

@MainActor
private func categoryManagementPreviewWithData() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Entry.self,
        Feed.self,
        Category.self,
        StoryGroup.self,
        configurations: config
    )
    let context = container.mainContext
    context.insert(Category(
        label: "technology",
        displayName: "Technology",
        categoryDescription: "News about technology companies and products.",
        sortOrder: 0
    ))
    context.insert(Category(
        label: "world",
        displayName: "World",
        categoryDescription: "Global policy and geopolitical developments.",
        sortOrder: 1
    ))
    try? context.save()

    return CategoryManagementView()
        .environment(ClassificationEngine())
        .modelContainer(container)
        .frame(width: 550, height: 500)
}

@MainActor
private func categoryManagementPreviewEmpty() -> some View {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(
        for: Entry.self,
        Feed.self,
        Category.self,
        StoryGroup.self,
        configurations: config
    )

    return CategoryManagementView()
        .environment(ClassificationEngine())
        .modelContainer(container)
        .frame(width: 550, height: 500)
}
