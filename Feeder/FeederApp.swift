import OSLog
import SwiftData
import SwiftUI

private let logger = Logger(subsystem: "com.feeder.app", category: "App")

/// Bump this when the SwiftData schema changes. On mismatch, articles
/// and feeds are deleted (categories preserved) and a fresh sync runs.
private let currentSchemaVersion = 9

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
    // swiftlint:disable:next large_tuple
    let defaults: [(label: String, displayName: String, description: String, sortOrder: Int, parentLabel: String?, keywords: [String])] = [
      // Top-level categories
      (
        "gaming", "Gaming",
        "Video game releases, reviews, gameplay content, announcements, and all game-specific news.",
        0, nil, ["xbox", "nintendo", "steam", "epic games"]
      ),
      (
        "technology", "Technology",
        "A broad category for all news about technology companies, products, platforms, and innovations.",
        1, nil, ["tech"]
      ),
      (
        "science", "Science",
        "Scientific discoveries, research, space exploration, astronomy, rockets, NASA, ESA, and related topics.",
        2, nil, ["nasa", "esa", "spacex", "rocket", "asteroid", "exoplanet", "james webb", "hubble"]
      ),
      (
        "world_news", "World News",
        "Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries.",
        3, nil, []
      ),
      (
        "whisky", "Whisky",
        "Articles about whisky — distilleries, reviews, tastings, industry news, and culture.",
        4, nil, ["whisky", "whiskey", "scotch", "bourbon", "distillery", "single malt", "islay"]
      ),
      (
        "buddhism", "Buddhism",
        "Articles about Buddhism, meditation, mindfulness, and spiritual topics. Do not include general health or fitness articles.",
        5, nil, ["buddhism", "buddhist", "meditation", "dharma", "mindfulness", "zen"]
      ),
      // Gaming children
      (
        "playstation_5", "PlayStation 5",
        "News about PlayStation 5 games, hardware, and ecosystem. Multiplatform news is acceptable if PS5 is one of the platforms. Exclude mobile gaming, PC-only gaming, and other console news.",
        0, "gaming", ["playstation 5", "ps5", "dualsense", "psn", "playstation"]
      ),
      (
        "marathon", "Marathon",
        "Articles about Marathon, the video game by developer Bungie.",
        1, "gaming", ["marathon", "bungie"]
      ),
      (
        "gaming_industry", "Gaming Industry",
        "Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes.",
        2, "gaming", ["layoffs", "acquisition", "studio closure"]
      ),
      // Technology children
      (
        "apple", "Apple",
        "All news related to Apple Inc., its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series, A-series), services, and innovations.",
        0, "technology",
        ["apple", "iphone", "ipad", "macbook", "macos", "ios", "watchos", "airpods", "apple watch", "vision pro", "apple intelligence"]
      ),
      (
        "tesla", "Tesla",
        "All news related to Tesla Inc., its vehicles, energy products, and innovations.",
        1, "technology", ["tesla", "cybertruck", "model 3", "model y", "model s", "model x", "supercharger"]
      ),
      (
        "rivian", "Rivian",
        "All news related to Rivian Automotive, its electric vehicles, technology, and business developments.",
        2, "technology", ["rivian", "r1t", "r1s", "r2", "r3"]
      ),
      (
        "ai", "AI",
        "Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies (OpenAI, Anthropic), and applied generative AI. Do not apply when a product merely uses AI as a feature.",
        3, "technology",
        [
          "openai", "chatgpt", "anthropic", "claude", "gemini", "llama",
          "midjourney", "stable diffusion", "machine learning", "deep learning", "neural network",
        ]
      ),
      (
        "home_automation", "Home Automation",
        "Smart home devices, appliances, home automation platforms (Home Assistant, Google Home, Apple HomeKit, Amazon Alexa), protocols (Matter, Thread, Z-Wave, Zigbee), and related IoT technologies for the home.",
        4, "technology",
        ["homekit", "home assistant", "matter", "alexa", "google home", "smart home", "zigbee", "thread", "z-wave"]
      ),
    ]
    for (label, displayName, description, sortOrder, parentLabel, keywords) in defaults {
      context.insert(
        Category(
          label: label, displayName: displayName, categoryDescription: description,
          sortOrder: sortOrder, parentLabel: parentLabel, keywords: keywords
        )
      )
    }
    context.insert(
      Category(
        label: uncategorizedLabel, displayName: "Uncategorized",
        categoryDescription: "Use only when no other category clearly matches. Never combine with another category.",
        sortOrder: Int.max, isSystem: true
      )
    )
    try? context.save()
    logger.info("Seeded \(defaults.count + 1) default categories on first launch.")
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
