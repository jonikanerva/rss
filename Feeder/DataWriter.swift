import Foundation
import OSLog
import SwiftData

// MARK: - Sendable DTOs for crossing actor boundaries

/// Input data for classification — extracted from Entry on background actor, consumed by FM inference.
nonisolated struct ClassificationInput: Sendable {
  let entryID: Int
  let title: String
  let body: String
}

/// Classification result — produced by FM inference, applied to Entry on background actor.
nonisolated struct ClassificationResult: Sendable {
  let entryID: Int
  let categoryLabels: [String]
  let storyKey: String
  let detectedLanguage: String
  let confidence: Double
}

/// Category definition — read from SwiftData, passed to classification as Sendable.
nonisolated struct CategoryDefinition: Sendable {
  let label: String
  let description: String
  let parentLabel: String?
  let isTopLevel: Bool
  let keywords: [String]

  init(label: String, description: String, parentLabel: String?, isTopLevel: Bool, keywords: [String] = []) {
    self.label = label
    self.description = description
    self.parentLabel = parentLabel
    self.isTopLevel = isTopLevel
    self.keywords = keywords
  }
}

// MARK: - Pure helper functions

/// Strip HTML tags and decode entities to produce plain text.
nonisolated func stripHTMLToPlainText(_ html: String) -> String {
  guard !html.isEmpty else { return "" }
  var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
  text = text.replacingOccurrences(of: "&amp;", with: "&")
  text = text.replacingOccurrences(of: "&lt;", with: "<")
  text = text.replacingOccurrences(of: "&gt;", with: ">")
  text = text.replacingOccurrences(of: "&quot;", with: "\"")
  text = text.replacingOccurrences(of: "&#39;", with: "'")
  text = text.replacingOccurrences(of: "&nbsp;", with: " ")
  text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Format a date for display: "Today, 5th Mar, 21:24" / "Yesterday, 4th Mar" / "Monday, 2nd Mar"
nonisolated func formatEntryDate(_ date: Date) -> String {
  let calendar = Calendar.current
  let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
  let day = calendar.component(.day, from: date)
  let suffix: String =
    switch day {
    case 11, 12, 13: "th"
    default:
      switch day % 10 {
      case 1: "st"
      case 2: "nd"
      case 3: "rd"
      default: "th"
      }
    }
  let month = date.formatted(.dateTime.month(.abbreviated))

  if calendar.isDateInToday(date) {
    return "Today, \(day)\(suffix) \(month), \(time)"
  } else if calendar.isDateInYesterday(date) {
    return "Yesterday, \(day)\(suffix) \(month), \(time)"
  } else {
    let weekday = date.formatted(.dateTime.weekday(.wide))
    return "\(weekday), \(day)\(suffix) \(month), \(time)"
  }
}

/// Extract display domain from a URL string, stripping the `www.` prefix.
/// e.g., "https://www.theverge.com/rss" → "theverge.com"
nonisolated func extractDomain(from urlString: String) -> String {
  guard let host = URL(string: urlString)?.host() else { return "" }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Safety net: strip parent labels when a more specific child label is present.
/// Given ["technology", "apple"] with apple being a child of technology, returns ["apple"].
nonisolated func enforceDeepestMatch(
  labels: [String],
  childrenByParent: [String: [CategoryDefinition]]
) -> [String] {
  var result = labels
  for (parentLabel, children) in childrenByParent {
    let childLabels = Set(children.map(\.label))
    if result.contains(parentLabel), result.contains(where: { childLabels.contains($0) }) {
      result.removeAll { $0 == parentLabel }
    }
  }
  return result.isEmpty ? [uncategorizedLabel] : result
}

// MARK: - DataWriter Actor

/// Background actor that owns all SwiftData write operations.
/// All data pre-computation (HTML stripping, date formatting) happens here, never on MainActor.
///
/// Uses ModelActor protocol with explicit init to guarantee the ModelContext
/// and its serial executor run on a background thread (not the cooperative pool's main thread).
actor DataWriter: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
  }

  private static let logger = Logger(subsystem: "com.feeder.app", category: "DataWriter")

  // MARK: - Feed persistence

  func syncFeeds(_ subscriptions: [FeedbinSubscription]) throws {
    let descriptor = FetchDescriptor<Feed>()
    let existingFeeds = try modelContext.fetch(descriptor)
    let existingByID = Dictionary(uniqueKeysWithValues: existingFeeds.map { ($0.feedbinSubscriptionID, $0) })

    for sub in subscriptions {
      if let existing = existingByID[sub.id] {
        existing.title = sub.title
        existing.feedURL = sub.feedUrl
        existing.siteURL = sub.siteUrl
      } else {
        let feed = Feed(
          feedbinSubscriptionID: sub.id,
          feedbinFeedID: sub.feedId,
          title: sub.title,
          feedURL: sub.feedUrl,
          siteURL: sub.siteUrl,
          createdAt: sub.createdAt
        )
        modelContext.insert(feed)
      }
    }
    try modelContext.save()
  }

  // MARK: - Icon persistence

  /// Persist favicon URLs and pre-fetched image data for feeds.
  /// Icon data fetching is done externally (SyncEngine) to keep DataWriter free of network I/O.
  func syncIcons(_ icons: [FeedbinIcon], prefetchedData: [String: Data]) throws {
    guard !icons.isEmpty else { return }
    let iconsByHost = Dictionary(icons.map { ($0.host, $0.url) }, uniquingKeysWith: { first, _ in first })

    let descriptor = FetchDescriptor<Feed>()
    let feeds = try modelContext.fetch(descriptor)

    var updated = 0
    for feed in feeds {
      guard let host = URL(string: feed.siteURL)?.host() else { continue }
      let lookupHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
      if let iconURL = iconsByHost[lookupHost] ?? iconsByHost[host] {
        if feed.faviconURL != iconURL || feed.faviconData == nil {
          feed.faviconURL = iconURL
          feed.faviconData = prefetchedData[iconURL]
          updated += 1
        }
      }
    }

    if updated > 0 {
      try modelContext.save()
      Self.logger.info("Updated favicon URLs for \(updated) feeds")
    }
  }

  // MARK: - Entry persistence

  func persistEntries(_ entries: [FeedbinEntry], markAsRead: Bool) throws -> Int {
    guard !entries.isEmpty else { return 0 }

    let entryIDs = entries.map(\.id)
    let existingDescriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in entryIDs.contains(entry.feedbinEntryID) }
    )
    let existingIDs = Set(try modelContext.fetch(existingDescriptor).map(\.feedbinEntryID))

    let feedDescriptor = FetchDescriptor<Feed>()
    let feedsByFeedbinID = Dictionary(
      uniqueKeysWithValues: try modelContext.fetch(feedDescriptor).map { ($0.feedbinFeedID, $0) }
    )

    var newCount = 0
    for dto in entries {
      if existingIDs.contains(dto.id) { continue }

      let entry = Entry(
        feedbinEntryID: dto.id,
        title: dto.title,
        author: dto.author,
        url: dto.url,
        content: dto.content,
        summary: dto.summary,
        extractedContentURL: dto.extractedContentUrl,
        publishedAt: dto.published,
        createdAt: dto.createdAt
      )
      entry.feed = feedsByFeedbinID[dto.feedId]
      entry.isRead = markAsRead
      let html = dto.content ?? dto.summary ?? ""
      let blocks = parseHTMLToBlocks(html)
      entry.articleBlocksData = blocks.toJSONData()
      entry.plainText = blocks.classificationText
      entry.summaryPlainText = stripHTMLToPlainText(dto.summary ?? "")
      entry.formattedDate = formatEntryDate(dto.published)
      entry.displayDomain = extractDomain(from: feedsByFeedbinID[dto.feedId]?.siteURL ?? dto.url)
      modelContext.insert(entry)
      newCount += 1
    }

    try modelContext.save()
    return newCount
  }

  func persistEntries(_ entries: [FeedbinEntry], unreadIDs: Set<Int>) throws -> Int {
    guard !entries.isEmpty else { return 0 }

    let entryIDs = entries.map(\.id)
    let existingDescriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in entryIDs.contains(entry.feedbinEntryID) }
    )
    let existingIDs = Set(try modelContext.fetch(existingDescriptor).map(\.feedbinEntryID))

    let feedDescriptor = FetchDescriptor<Feed>()
    let feedsByFeedbinID = Dictionary(
      uniqueKeysWithValues: try modelContext.fetch(feedDescriptor).map { ($0.feedbinFeedID, $0) }
    )

    var newCount = 0
    for dto in entries {
      if existingIDs.contains(dto.id) { continue }

      let entry = Entry(
        feedbinEntryID: dto.id,
        title: dto.title,
        author: dto.author,
        url: dto.url,
        content: dto.content,
        summary: dto.summary,
        extractedContentURL: dto.extractedContentUrl,
        publishedAt: dto.published,
        createdAt: dto.createdAt
      )
      entry.feed = feedsByFeedbinID[dto.feedId]
      entry.isRead = !unreadIDs.contains(dto.id)
      let html = dto.content ?? dto.summary ?? ""
      let blocks = parseHTMLToBlocks(html)
      entry.articleBlocksData = blocks.toJSONData()
      entry.plainText = blocks.classificationText
      entry.summaryPlainText = stripHTMLToPlainText(dto.summary ?? "")
      entry.formattedDate = formatEntryDate(dto.published)
      entry.displayDomain = extractDomain(from: feedsByFeedbinID[dto.feedId]?.siteURL ?? dto.url)
      modelContext.insert(entry)
      newCount += 1
    }

    try modelContext.save()
    return newCount
  }

  // MARK: - Read state

  func updateReadState(unreadIDs: Set<Int>) throws {
    let descriptor = FetchDescriptor<Entry>()
    let allEntries = try modelContext.fetch(descriptor)

    var updatedCount = 0
    for entry in allEntries {
      let shouldBeRead = !unreadIDs.contains(entry.feedbinEntryID)
      if entry.isRead != shouldBeRead {
        entry.isRead = shouldBeRead
        updatedCount += 1
      }
    }

    if updatedCount > 0 {
      try modelContext.save()
      Self.logger.info("Updated read state for \(updatedCount) entries")
    }
  }

  func markEntryRead(feedbinEntryID: Int) throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.feedbinEntryID == feedbinEntryID }
    )
    guard let entry = try modelContext.fetch(descriptor).first, !entry.isRead else { return }
    entry.isRead = true
    try modelContext.save()
  }

  /// Batch mark multiple entries as read in a single save.
  func markEntriesRead(feedbinEntryIDs ids: Set<Int>) throws {
    guard !ids.isEmpty else { return }
    let idArray = Array(ids)
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { idArray.contains($0.feedbinEntryID) && !$0.isRead }
    )
    let entries = try modelContext.fetch(descriptor)
    guard !entries.isEmpty else { return }
    for entry in entries {
      entry.isRead = true
    }
    try modelContext.save()
  }

  /// Mark all unread classified entries in a category as read. Returns the feedbin entry IDs that were marked.
  func markAllAsRead(category: String, cutoffDate: Date) throws -> Set<Int> {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> {
        $0.isClassified && $0.primaryCategory == category && !$0.isRead
          && $0.publishedAt >= cutoffDate
      }
    )
    let entries = try modelContext.fetch(descriptor)
    guard !entries.isEmpty else { return [] }
    var markedIDs = Set<Int>()
    for entry in entries {
      entry.isRead = true
      markedIDs.insert(entry.feedbinEntryID)
    }
    try modelContext.save()
    Self.logger.info("Marked \(markedIDs.count) entries as read in category '\(category)'")
    return markedIDs
  }

  // MARK: - Extracted content

  func fetchExtractedContentRequests() throws -> [(entryID: Int, url: String)] {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.extractedContentURL != nil && $0.extractedContent == nil }
    )
    return try modelContext.fetch(descriptor).compactMap { entry in
      guard let url = entry.extractedContentURL else { return nil }
      return (entryID: entry.feedbinEntryID, url: url)
    }
  }

  func applyExtractedContent(results: [(entryID: Int, content: String)]) throws {
    guard !results.isEmpty else { return }
    let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.entryID, $0.content) })
    let ids = results.map(\.entryID)

    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in ids.contains(entry.feedbinEntryID) }
    )
    let entries = try modelContext.fetch(descriptor)

    for entry in entries {
      if let content = resultsByID[entry.feedbinEntryID] {
        entry.extractedContent = content
        let blocks = parseHTMLToBlocks(content)
        entry.articleBlocksData = blocks.toJSONData()
        entry.plainText = blocks.classificationText
        entry.invalidateBlocksCache()
      }
    }
    try modelContext.save()
  }

  // MARK: - Classification

  func fetchUnclassifiedInputs(cutoffDate: Date) throws -> [ClassificationInput] {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { !$0.isClassified && $0.publishedAt >= cutoffDate },
      sortBy: [SortDescriptor(\Entry.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor).map { entry in
      ClassificationInput(
        entryID: entry.feedbinEntryID,
        title: entry.title ?? "Untitled",
        body: entry.plainText
      )
    }
  }

  func fetchCategoryDefinitions() throws -> [CategoryDefinition] {
    var descriptor = FetchDescriptor<Category>()
    descriptor.sortBy = [SortDescriptor(\Category.sortOrder)]
    return try modelContext.fetch(descriptor).map { cat in
      CategoryDefinition(
        label: cat.label,
        description: cat.categoryDescription,
        parentLabel: cat.parentLabel,
        isTopLevel: cat.isTopLevel,
        keywords: cat.keywords
      )
    }
  }

  func applyClassification(entryID: Int, result: ClassificationResult) throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in entry.feedbinEntryID == entryID }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return }

    // Safety net: strip parent labels when a child label is also present (deepest-match rule)
    let categories = try fetchCategoryDefinitions()
    let childrenByParent = Dictionary(
      grouping: categories.filter { !$0.isTopLevel },
      by: { $0.parentLabel ?? "" }
    )
    let labels = enforceDeepestMatch(labels: result.categoryLabels, childrenByParent: childrenByParent)

    entry.detectedLanguage = result.detectedLanguage
    entry.categoryLabels = labels
    entry.storyKey = result.storyKey
    entry.isClassified = true
    entry.primaryCategory = labels.first ?? uncategorizedLabel
    try modelContext.save()
  }

  func resetClassification() throws {
    let descriptor = FetchDescriptor<Entry>()
    let entries = try modelContext.fetch(descriptor)
    for entry in entries {
      entry.categoryLabels = []
      entry.storyKey = nil
      entry.detectedLanguage = nil
      entry.isClassified = false
      entry.primaryCategory = ""
    }
    try modelContext.save()
  }

  // MARK: - Purge

  // MARK: - Category management

  func addCategory(label: String, displayName: String, description: String, sortOrder: Int, parentLabel: String? = nil) throws {
    let category = Category(
      label: label,
      displayName: displayName,
      categoryDescription: description,
      sortOrder: sortOrder,
      parentLabel: parentLabel
    )
    modelContext.insert(category)
    try modelContext.save()
  }

  func deleteCategory(label: String) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    guard !category.isSystem else { return }

    if category.isTopLevel {
      let childDescriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.parentLabel == label }
      )
      let kids = try modelContext.fetch(childDescriptor)
      for child in kids {
        modelContext.delete(child)
      }
    }
    modelContext.delete(category)
    try modelContext.save()
  }

  func fetchCategorySortOrder(label: String) throws -> Int? {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    return try modelContext.fetch(descriptor).first?.sortOrder
  }

  func childCategoryNames(for parentLabel: String) throws -> [String] {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.parentLabel == parentLabel },
      sortBy: [SortDescriptor(\Category.sortOrder)]
    )
    return try modelContext.fetch(descriptor).map(\.displayName)
  }

  func updateCategorySortOrders(_ updates: [(label: String, sortOrder: Int)]) throws {
    for (label, sortOrder) in updates {
      let descriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == label }
      )
      if let category = try modelContext.fetch(descriptor).first, !category.isSystem {
        category.sortOrder = sortOrder
      }
    }
    try modelContext.save()
  }

  func updateCategoryHierarchy(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first, !category.isSystem else { return }
    if let parentLabel {
      let parentDescriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == parentLabel }
      )
      if let parent = try modelContext.fetch(parentDescriptor).first, parent.isSystem { return }
    }
    category.parentLabel = parentLabel
    category.depth = depth
    category.isTopLevel = isTopLevel
    category.sortOrder = sortOrder
    try modelContext.save()
  }

  func batchUpdateCategoryHierarchyAndSortOrders(
    hierarchyChanges: [(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int)],
    sortOrderUpdates: [(label: String, sortOrder: Int)]
  ) throws {
    for change in hierarchyChanges {
      let targetLabel = change.label
      let descriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == targetLabel }
      )
      guard let category = try modelContext.fetch(descriptor).first, !category.isSystem else { continue }
      if let parentLabel = change.parentLabel {
        let parentDescriptor = FetchDescriptor<Category>(
          predicate: #Predicate<Category> { $0.label == parentLabel }
        )
        if let parent = try modelContext.fetch(parentDescriptor).first, parent.isSystem { continue }
      }
      category.parentLabel = change.parentLabel
      category.depth = change.depth
      category.isTopLevel = change.isTopLevel
      category.sortOrder = change.sortOrder
    }
    for (label, sortOrder) in sortOrderUpdates {
      let descriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == label }
      )
      if let category = try modelContext.fetch(descriptor).first, !category.isSystem {
        category.sortOrder = sortOrder
      }
    }
    try modelContext.save()
  }

  func updateSystemFlag(label: String, isSystem: Bool) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    category.isSystem = isSystem
    try modelContext.save()
  }

  func updateCategoryFields(label: String, displayName: String, description: String) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    if !category.isSystem { category.displayName = displayName }
    category.categoryDescription = description
    try modelContext.save()
  }

  func seedDefaultCategories(
    _ definitions: [(label: String, displayName: String, description: String, sortOrder: Int, parentLabel: String?)]
  ) throws {
    for (label, displayName, description, sortOrder, parentLabel) in definitions {
      let category = Category(
        label: label,
        displayName: displayName,
        categoryDescription: description,
        sortOrder: sortOrder,
        parentLabel: parentLabel
      )
      modelContext.insert(category)
    }
    try modelContext.save()
  }

  // MARK: - UI test seeding

  func seedUITestData() throws -> Bool {
    let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Entry>())) ?? 0
    guard existingCount == 0 else { return false }

    let technology = Category(
      label: "technology", displayName: "Technology",
      categoryDescription: "Technology coverage for local UI testing", sortOrder: 0)
    let apple = Category(
      label: "apple", displayName: "Apple",
      categoryDescription: "Apple news for local UI testing", sortOrder: 0,
      parentLabel: "technology")
    let world = Category(
      label: "world_news", displayName: "World News",
      categoryDescription: "World news coverage for local UI testing", sortOrder: 1)
    modelContext.insert(technology)
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
      entry.categoryLabels = ["technology"]
      entry.primaryCategory = "technology"
      entry.storyKey = "sample-tech-story-\(index)"
      entry.isClassified = true
      entry.formattedDate = formatEntryDate(entry.publishedAt)
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
    worldEntry.categoryLabels = ["world_news", "technology"]
    worldEntry.primaryCategory = "world_news"
    worldEntry.storyKey = "eu-ai-transparency-framework"
    worldEntry.isClassified = true
    worldEntry.formattedDate = formatEntryDate(worldEntry.publishedAt)
    worldEntry.displayDomain = extractDomain(from: worldEntry.feed?.siteURL ?? "")
    worldEntry.plainText = "European lawmakers finalized a new AI framework."
    worldEntry.summaryPlainText = "EU finalizes AI transparency framework."
    worldEntry.isRead = false
    modelContext.insert(worldEntry)

    try modelContext.save()
    return true
  }

  // MARK: - Purge

  func purgeEntriesOlderThan(_ cutoff: Date) throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.publishedAt < cutoff }
    )
    let old = try modelContext.fetch(descriptor)
    guard !old.isEmpty else { return }
    for entry in old {
      modelContext.delete(entry)
    }
    try modelContext.save()
    Self.logger.info("Purged \(old.count) entries older than cutoff")
  }
}
