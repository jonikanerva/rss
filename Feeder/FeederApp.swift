import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch, articles
/// and feeds are deleted (categories preserved) and a fresh sync runs.
private let currentSchemaVersion = 7

@main
struct FeederApp: App {
  let modelContainer: ModelContainer

  @State
  private var syncEngine = SyncEngine()
  @State
  private var classificationEngine = ClassificationEngine()

  init() {
    let processEnvironment = ProcessInfo.processInfo.environment
    let useInMemoryStore =
      processEnvironment["UITEST_IN_MEMORY_STORE"] == "1" || processEnvironment["UITEST_DEMO_MODE"] == "1"

    let schema = Schema([
      Feed.self,
      Entry.self,
      Category.self,
    ])
    let config = ModelConfiguration("Feeder", isStoredInMemoryOnly: useInMemoryStore)

    // If the store can't be opened (schema incompatible), delete it and retry
    do {
      modelContainer = try ModelContainer(for: schema, configurations: [config])
    } catch {
      logger.error("ModelContainer failed: \(error.localizedDescription). Deleting store and retrying.")
      Self.deleteStoreFiles()
      UserDefaults.standard.removeObject(forKey: "lastSyncDate")
      UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
      do {
        modelContainer = try ModelContainer(for: schema, configurations: [config])
      } catch {
        fatalError("Failed to create ModelContainer after reset: \(error)")
      }
    }

    if !useInMemoryStore {
      resetArticlesIfSchemaChanged()
    }

    let context = ModelContext(modelContainer)
    let feedCount = (try? context.fetchCount(FetchDescriptor<Feed>())) ?? 0
    let entryCount = (try? context.fetchCount(FetchDescriptor<Entry>())) ?? 0
    let categoryCount = (try? context.fetchCount(FetchDescriptor<Category>())) ?? 0

    if categoryCount == 0 {
      seedDefaultCategories(into: context)
    }

    let lastSync = UserDefaults.standard.object(forKey: "lastSyncDate") as? Date
    logger.info(
      "Startup: schema v\(currentSchemaVersion), \(feedCount) feeds, \(entryCount) entries, \(categoryCount) categories. Last sync: \(lastSync?.description ?? "never"). In-memory: \(useInMemoryStore)"
    )
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(syncEngine)
        .environment(classificationEngine)
    }
    .modelContainer(modelContainer)

    Settings {
      SettingsView()
        .environment(syncEngine)
        .environment(classificationEngine)
        .modelContainer(modelContainer)
    }
    .windowResizability(.contentSize)
  }

  // MARK: - First-launch category seeding
  // Bootstrap exception: writes directly to ModelContext during init(), before any views
  // or @Query are active. DataWriter is not yet available (SyncEngine.configure() hasn't
  // been called). This pattern matches resetArticlesIfSchemaChanged() above.

  private func seedDefaultCategories(into context: ModelContext) {
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
    for (label, displayName, description, sortOrder, parentLabel) in defaults {
      context.insert(
        Category(
          label: label, displayName: displayName, categoryDescription: description,
          sortOrder: sortOrder, parentLabel: parentLabel
        )
      )
    }
    try? context.save()
    logger.info("Seeded \(defaults.count) default categories on first launch.")
  }

  // MARK: - Schema versioning

  /// Clear articles and feeds when schema version changes. Categories are preserved.
  private func resetArticlesIfSchemaChanged() {
    let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
    guard stored != currentSchemaVersion else { return }

    logger.info("Schema version changed (\(stored) → \(currentSchemaVersion)). Clearing articles.")

    let context = ModelContext(modelContainer)
    let feeds = (try? context.fetch(FetchDescriptor<Feed>())) ?? []
    for feed in feeds {
      context.delete(feed)  // cascade deletes feed's entries
    }
    // Delete any orphaned entries (no feed)
    let entries = (try? context.fetch(FetchDescriptor<Entry>())) ?? []
    for entry in entries {
      context.delete(entry)
    }
    try? context.save()

    UserDefaults.standard.removeObject(forKey: "lastSyncDate")
    UserDefaults.standard.set(currentSchemaVersion, forKey: schemaVersionKey)
    logger.info("Articles cleared. Categories preserved. Will sync fresh.")
  }

  /// Delete SwiftData store files from disk (fallback when store can't be opened at all).
  private static func deleteStoreFiles() {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    for suffix in ["store", "store-shm", "store-wal"] {
      let url = appSupport.appendingPathComponent("Feeder.\(suffix)")
      try? FileManager.default.removeItem(at: url)
    }
  }
}

private let schemaVersionKey = "feeder_schema_version"
