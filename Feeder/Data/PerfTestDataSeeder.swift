import Foundation
import SwiftData

// MARK: - Deterministic RNG

/// Linear congruential generator initialised from a fixed seed. Used by
/// `seedPerfTestData` so every perf-mode launch fans entries across the same
/// categories in the same order — runs are comparable without depending on
/// `SystemRandomNumberGenerator`.
///
/// `nonisolated` so it is callable from any actor context. Not cryptographic —
/// we only need reproducibility and a uniform spread across a small label set.
nonisolated struct DeterministicRandomNumberGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed &+ 0x9E37_79B9_7F4A_7C15
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

// MARK: - Perf seeding

extension DataWriter {
  /// Populate an empty in-memory store with a deterministic, perf-realistic
  /// dataset: `categoryCount` evenly-balanced classified categories under a
  /// pair of folders, `entryCount` entries split across them, ~50/50 read /
  /// unread, pre-computed display fields populated so the perf scenario
  /// exercises the same hot fields the production timeline reads.
  ///
  /// Returns `true` when seeding ran, `false` if the store already held data
  /// (perf launches always run against a fresh in-memory container so this
  /// guard is defensive). Kept on the `DataWriter` `@ModelActor` per
  /// `docs/swift-code-rules.md → Two-Layer Architecture` — no MainActor work
  /// during seeding.
  func seedPerfTestData(entryCount: Int = 5000, categoryCount: Int = 12) throws -> Bool {
    let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Entry>())) ?? 0
    guard existingCount == 0 else { return false }

    let folders = perfSeedFolders()
    for folder in folders {
      modelContext.insert(folder)
    }

    let categories = perfSeedCategories(count: categoryCount)
    for category in categories {
      modelContext.insert(category)
    }

    let feeds = perfSeedFeeds()
    for feed in feeds {
      modelContext.insert(feed)
    }

    let baseDate = Date()
    var rng = DeterministicRandomNumberGenerator(seed: 0xFEED_E5_00)

    for index in 0..<entryCount {
      let categoryIndex = index % categories.count
      let category = categories[categoryIndex]
      let feed = feeds[index % feeds.count]
      // Spread published timestamps across ~30 days. The article-list query
      // honours a 30-day cutoff, so this keeps every seeded row eligible
      // for the timeline without the cutoff trimming the dataset.
      let secondsOffset = Double(index) * 240 + Double.random(in: 0..<60, using: &rng)
      let publishedAt = baseDate.addingTimeInterval(-secondsOffset)
      let summaryHTML = "<p>Perf scenario story \(index) for category \(category.label).</p>"
      let entry = Entry(
        feedbinEntryID: 10_000 + index,
        title: "Perf Scenario Story \(index)",
        author: "Perf Bot",
        url: "https://example.com/perf/\(index)",
        content: summaryHTML,
        summary: "Perf scenario story \(index)",
        extractedContentURL: nil,
        publishedAt: publishedAt,
        createdAt: publishedAt
      )
      entry.feed = feed
      entry.primaryCategory = category.label
      entry.primaryFolder = category.folderLabel ?? ""
      entry.isClassified = true
      entry.isRead = index.isMultiple(of: 2)
      entry.plainText = "Perf scenario story \(index) for category \(category.label)."
      entry.summaryPlainText = entry.plainText
      entry.formattedDate = formatEntryDate(publishedAt)
      entry.formattedPublishedTime = formatEntryTime(publishedAt)
      entry.displayDomain = extractDomain(from: feed.siteURL)
      modelContext.insert(entry)
    }

    try modelContext.save()
    return true
  }

  // MARK: - Helpers

  private func perfSeedFolders() -> [Folder] {
    [
      Folder(label: "technology", displayName: "Technology", sortOrder: 0),
      Folder(label: "world", displayName: "World", sortOrder: 1),
    ]
  }

  private func perfSeedCategories(count: Int) -> [Category] {
    // First half assigned to "technology", second half assigned to "world",
    // giving the sidebar two non-empty folder aggregates plus a flat list of
    // category leaves. Deterministic labels so the runner can drive a known
    // selection sequence without depending on default taxonomy ordering.
    (0..<count).map { index in
      let folderLabel = index < count / 2 ? "technology" : "world"
      return Category(
        label: "perf_\(index)",
        displayName: "Perf \(index)",
        categoryDescription: "Perf category \(index)",
        sortOrder: index,
        folderLabel: folderLabel
      )
    }
  }

  private func perfSeedFeeds() -> [Feed] {
    (0..<4).map { index in
      Feed(
        feedbinSubscriptionID: 9_000 + index,
        feedbinFeedID: 9_000 + index,
        title: "Perf Feed \(index)",
        feedURL: "https://example.com/perf-\(index)/feed",
        siteURL: "https://perf-\(index).example.com",
        createdAt: .now
      )
    }
  }
}
