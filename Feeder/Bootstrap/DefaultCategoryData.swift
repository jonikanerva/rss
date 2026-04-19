import Foundation
import OSLog
import SwiftData

private let seedingLogger = Logger(subsystem: "com.feeder.app", category: "DefaultCategoryData")

/// First-launch taxonomy shipped with the app. Kept in its own file so
/// `FeederApp` stays focused on lifecycle and the seed data is easy to review.
enum DefaultCategoryData {
  struct FolderDefinition {
    let label: String
    let displayName: String
    let sortOrder: Int
  }

  struct CategoryDefinition {
    let label: String
    let displayName: String
    let description: String
    let sortOrder: Int
    let folderLabel: String?
    let keywords: [String]
  }

  static let folders: [FolderDefinition] = [
    .init(label: "gaming", displayName: "Gaming", sortOrder: 0),
    .init(label: "technology", displayName: "Technology", sortOrder: 1),
  ]

  static let categories: [CategoryDefinition] = [
    // Gaming folder categories
    .init(
      label: "playstation_5", displayName: "PlayStation 5",
      description:
        "News about PlayStation 5 games, hardware, and ecosystem. Multiplatform news is acceptable if PS5 is one of the platforms. Exclude mobile gaming, PC-only gaming, and other console news.",
      sortOrder: 0, folderLabel: "gaming",
      keywords: ["playstation 5", "ps5", "dualsense", "psn", "playstation"]),
    .init(
      label: "marathon", displayName: "Marathon",
      description: "Articles about Marathon, the video game by developer Bungie.",
      sortOrder: 1, folderLabel: "gaming", keywords: ["marathon", "bungie"]),
    .init(
      label: "gaming_industry", displayName: "Gaming Industry",
      description:
        "Business and industry news about the gaming sector: studio layoffs, closures, acquisitions, insolvency, market analysis, financial results, and workforce changes.",
      sortOrder: 2, folderLabel: "gaming",
      keywords: ["layoffs", "acquisition", "studio closure"]),
    .init(
      label: "video_games", displayName: "Video Games",
      description:
        "All other articles about video games, PC games, console games, or other gaming topics that do not fit PlayStation 5, Marathon, or Gaming Industry categories.",
      sortOrder: 3, folderLabel: "gaming",
      keywords: ["xbox", "nintendo", "steam", "epic games"]),
    // Technology folder categories
    .init(
      label: "apple", displayName: "Apple",
      description:
        "All news related to Apple Inc., its products (Mac, iPhone, iPad, Apple Watch), platforms (macOS, iOS), chips (M-series, A-series), services, and innovations.",
      sortOrder: 0, folderLabel: "technology",
      keywords: [
        "apple", "iphone", "ipad", "macbook", "macos", "ios", "watchos", "airpods", "apple watch",
        "vision pro", "apple intelligence",
      ]),
    .init(
      label: "tesla", displayName: "Tesla",
      description: "All news related to Tesla Inc., its vehicles, energy products, and innovations.",
      sortOrder: 1, folderLabel: "technology",
      keywords: ["tesla", "cybertruck", "model 3", "model y", "model s", "model x", "supercharger"]),
    .init(
      label: "rivian", displayName: "Rivian",
      description:
        "All news related to Rivian Automotive, its electric vehicles, technology, and business developments.",
      sortOrder: 2, folderLabel: "technology", keywords: ["rivian", "r1t", "r1s", "r2", "r3"]),
    .init(
      label: "ai", displayName: "AI",
      description:
        "Only for articles where AI is the central topic: AI models, ML systems, AI products, AI-focused companies (OpenAI, Anthropic), and applied generative AI. Do not apply when a product merely uses AI as a feature.",
      sortOrder: 3, folderLabel: "technology",
      keywords: [
        "openai", "chatgpt", "anthropic", "claude", "gemini", "llama",
        "midjourney", "stable diffusion", "machine learning", "deep learning", "neural network",
      ]),
    .init(
      label: "home_automation", displayName: "Home Automation",
      description:
        "Smart home devices, appliances, home automation platforms (Home Assistant, Google Home, Apple HomeKit, Amazon Alexa), protocols (Matter, Thread, Z-Wave, Zigbee), and related IoT technologies for the home.",
      sortOrder: 4, folderLabel: "technology",
      keywords: [
        "homekit", "home assistant", "matter", "alexa", "google home", "smart home", "zigbee", "thread",
        "z-wave",
      ]),
    .init(
      label: "technology_general", displayName: "Technology",
      description:
        "All other technology articles that do not fit a more specific technology category (Apple, Tesla, Rivian, AI, Home Automation). Use this as the fallback within technology topics.",
      sortOrder: 5, folderLabel: "technology", keywords: ["tech"]),
    // Root-level categories (no folder)
    .init(
      label: "science", displayName: "Science",
      description:
        "Scientific discoveries, research, space exploration, astronomy, rockets, NASA, ESA, and related topics.",
      sortOrder: 0, folderLabel: nil,
      keywords: ["nasa", "esa", "spacex", "rocket", "asteroid", "exoplanet", "james webb", "hubble"]),
    .init(
      label: "world_news", displayName: "World News",
      description:
        "Geopolitics, government actions, regulatory decisions, international affairs, and global developments. Only apply when government or policy is a central theme, not when a company merely operates in multiple countries.",
      sortOrder: 1, folderLabel: nil, keywords: []),
    .init(
      label: "whisky", displayName: "Whisky",
      description:
        "Articles about whisky — distilleries, reviews, tastings, industry news, and culture.",
      sortOrder: 2, folderLabel: nil,
      keywords: ["whisky", "whiskey", "scotch", "bourbon", "distillery", "single malt", "islay"]),
    .init(
      label: "buddhism", displayName: "Buddhism",
      description:
        "Articles about Buddhism, meditation, mindfulness, and spiritual topics. Do not include general health or fitness articles.",
      sortOrder: 3, folderLabel: nil,
      keywords: ["buddhism", "buddhist", "meditation", "dharma", "mindfulness", "zen"]),
  ]

  /// Insert folders, categories, and the system `uncategorized` fallback into
  /// the given context, then save. Expected to run only on first launch when
  /// the categories table is empty — `FeederApp` guards that condition.
  ///
  /// Bootstrap exception: writes directly to `ModelContext` during app
  /// `init()`, before any views or `@Query` are active. `DataWriter` is not yet
  /// available (SyncEngine.configure() hasn't been called). Parallel path to
  /// `FeederApp.resetArticlesIfSchemaChanged()`, which uses the same pattern.
  static func seed(into context: ModelContext) {
    for folder in folders {
      context.insert(Folder(label: folder.label, displayName: folder.displayName, sortOrder: folder.sortOrder))
    }
    for category in categories {
      context.insert(
        Category(
          label: category.label,
          displayName: category.displayName,
          categoryDescription: category.description,
          sortOrder: category.sortOrder,
          folderLabel: category.folderLabel,
          keywords: category.keywords
        )
      )
    }
    context.insert(
      Category(
        label: uncategorizedLabel,
        displayName: "Uncategorized",
        categoryDescription: "Use only when no other category clearly matches.",
        sortOrder: Int.max,
        isSystem: true
      )
    )
    try? context.save()
    seedingLogger.info(
      "Seeded \(folders.count) folders and \(categories.count + 1) categories on first launch."
    )
  }
}
