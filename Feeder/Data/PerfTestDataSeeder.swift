import Foundation
import SwiftData

// MARK: - Deterministic RNG

/// Linear congruential generator from a fixed seed, so every perf launch fans
/// entries across the same categories in the same order and the runs stay
/// comparable. Not cryptographic: it needs reproducibility and a uniform spread
/// across a small label set, nothing more.
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
  /// Populate an empty in-memory store with a deterministic dataset: balanced
  /// classified categories under a pair of folders, entries split across them
  /// with a mix of read state, and the pre-computed display fields filled, so
  /// the scenario exercises the same hot fields the production timeline reads.
  ///
  /// Returns `true` when seeding ran and `false` when the store already held
  /// data. It stays on the writer actor, so no seeding work reaches MainActor.
  func seedPerfTestData(entryCount: Int = 5000, categoryCount: Int = 12) throws -> Bool {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
      // Spread the timestamps inside the retention window, so the cutoff in
      // the article-list query trims none of the dataset.
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
      // Split the read state within each category, so the unread query returns
      // rows for every one of them. Keying on the flat index alone collapses a
      // category to all-read or all-unread when the category count is even.
      entry.isRead = (index / categories.count).isMultiple(of: 2)
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

  /// Insert one write-pressure batch inside the selected sidebar item's
  /// predicate, so the article pane's refetch and re-render actually fire. A
  /// save the visible list ignores would not exercise the contention.
  ///
  /// Every row is eligible for the unread query: classified, unread, and
  /// published inside the cutoff window. The caller passes the live selection,
  /// so each batch targets whatever the user is looking at.
  ///
  /// `startingID` must sit above the main seed's range, and the returned next
  /// free ID threads into the following batch, or the unique attribute on
  /// `feedbinEntryID` collides.
  func seedPerfTestBatch(
    count: Int,
    matching selection: SidebarSelection,
    startingID: Int
  ) throws -> Int {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard count > 0 else { return startingID }

    // Reuse an existing feed, so the rows carry a display domain like the main
    // seed's. A store seeded without feeds falls back to a synthesized URL.
    let feed = try? modelContext.fetch(FetchDescriptor<Feed>()).first
    let siteURL = feed?.siteURL ?? "https://perf.example.com"

    let category: String
    let folder: String
    switch selection {
    case .category(let label): (category, folder) = (label, "")
    case .folder(let label): (category, folder) = ("", label)
    }

    let now = Date()
    for offset in 0..<count {
      let id = startingID + offset
      // A sub-second spread keeps each timestamp distinct inside the cutoff
      // window. Ordering is not asserted for pressure rows.
      let publishedAt = now.addingTimeInterval(-Double(offset) * 0.001)
      let summaryHTML = "<p>Perf pressure story \(id).</p>"
      let entry = Entry(
        feedbinEntryID: id,
        title: "Perf Pressure Story \(id)",
        author: "Perf Bot",
        url: "https://example.com/perf-pressure/\(id)",
        content: summaryHTML,
        summary: "Perf pressure story \(id)",
        extractedContentURL: nil,
        publishedAt: publishedAt,
        createdAt: publishedAt
      )
      entry.feed = feed
      entry.primaryCategory = category
      entry.primaryFolder = folder
      entry.isClassified = true
      entry.isRead = false
      entry.plainText = "Perf pressure story \(id)."
      entry.summaryPlainText = entry.plainText
      entry.formattedDate = formatEntryDate(publishedAt)
      entry.formattedPublishedTime = formatEntryTime(publishedAt)
      entry.displayDomain = extractDomain(from: siteURL)
      modelContext.insert(entry)
    }

    try modelContext.save()
    return startingID + count
  }

  // MARK: - Helpers

  private func perfSeedFolders() -> [Folder] {
    [
      Folder(label: "technology", displayName: "Technology", sortOrder: 0),
      Folder(label: "world", displayName: "World", sortOrder: 1),
    ]
  }

  private func perfSeedCategories(count: Int) -> [Category] {
    // Half the categories go to each folder, so the sidebar shows two non-empty
    // aggregates over a flat list of leaves. The labels are deterministic, so
    // the runner drives a known selection sequence.
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
