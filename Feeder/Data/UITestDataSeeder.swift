import Foundation
import SwiftData

// MARK: - UI Test Seeding

/// Seed demo data used by UI tests in in-memory mode. Kept separate from the
/// production `DataWriter` actor so the actor file stays focused on write ops.
extension DataWriter {
  /// Populate an empty in-memory store with a fixed set of feeds, categories,
  /// and classified entries. Returns `true` if seeding ran, `false` if entries
  /// already existed.
  func seedUITestData() throws -> Bool {
    let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Entry>())) ?? 0
    guard existingCount == 0 else { return false }

    let techFolder = Folder(label: "technology", displayName: "Technology", sortOrder: 0)
    modelContext.insert(techFolder)

    let apple = Category(
      label: "apple", displayName: "Apple",
      categoryDescription: "Apple news for local UI testing", sortOrder: 0,
      folderLabel: "technology")
    let world = Category(
      label: "world_news", displayName: "World News",
      categoryDescription: "World news coverage for local UI testing", sortOrder: 1)
    modelContext.insert(apple)
    modelContext.insert(world)

    let feed1 = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "The Verge",
      feedURL: "https://theverge.com/rss", siteURL: "https://theverge.com", createdAt: .now)
    let feed2 = Feed(
      feedbinSubscriptionID: 2, feedbinFeedID: 2, title: "Ars Technica",
      feedURL: "https://arstechnica.com/rss", siteURL: "https://arstechnica.com", createdAt: .now)
    modelContext.insert(feed1)
    modelContext.insert(feed2)

    for index in 1...12 {
      let entry = Entry(
        feedbinEntryID: 1000 + index,
        title: "Sample Tech Story \(index)",
        author: "Feeder Bot",
        url: "https://example.com/story/\(1000 + index)",
        content: "<p>Sample article \(index) for local UX smoke testing.</p>",
        summary: "Sample article \(index)",
        extractedContentURL: nil,
        publishedAt: .now.addingTimeInterval(-Double(index) * 900),
        createdAt: .now.addingTimeInterval(-Double(index) * 850)
      )
      entry.feed = index.isMultiple(of: 2) ? feed1 : feed2
      entry.primaryCategory = "apple"
      entry.primaryFolder = "technology"
      entry.storyKey = "sample-tech-story-\(index)"
      entry.isClassified = true
      entry.formattedDate = formatEntryDate(entry.publishedAt)
      entry.formattedPublishedTime = formatEntryTime(entry.publishedAt)

      entry.displayDomain = extractDomain(from: entry.feed?.siteURL ?? "")
      entry.plainText = "Sample article \(index) for local UX smoke testing."
      entry.summaryPlainText = "Sample article \(index)"
      entry.isRead = index.isMultiple(of: 3)
      modelContext.insert(entry)
    }

    let worldEntry = Entry(
      feedbinEntryID: 2001,
      title: "EU passes major AI transparency framework",
      author: "Policy Desk",
      url: "https://example.com/story/2001",
      content: "<p>European lawmakers finalized a new AI framework.</p>",
      summary: "EU finalizes AI transparency framework.",
      extractedContentURL: nil,
      publishedAt: .now.addingTimeInterval(-7200),
      createdAt: .now.addingTimeInterval(-7100)
    )
    worldEntry.feed = feed1
    worldEntry.primaryCategory = "world_news"
    worldEntry.primaryFolder = ""
    worldEntry.storyKey = "eu-ai-transparency-framework"
    worldEntry.isClassified = true
    worldEntry.formattedDate = formatEntryDate(worldEntry.publishedAt)
    worldEntry.formattedPublishedTime = formatEntryTime(worldEntry.publishedAt)
    worldEntry.displayDomain = extractDomain(from: worldEntry.feed?.siteURL ?? "")
    worldEntry.plainText = "European lawmakers finalized a new AI framework."
    worldEntry.summaryPlainText = "EU finalizes AI transparency framework."
    worldEntry.isRead = false
    modelContext.insert(worldEntry)

    try modelContext.save()
    return true
  }
}
