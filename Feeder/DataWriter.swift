import Foundation
import OSLog
import SwiftData

// MARK: - Sendable DTOs for crossing actor boundaries

/// Input data for classification — extracted from Entry on background actor, consumed by FM inference.
nonisolated struct ClassificationInput: Sendable {
  let entryID: Int
  let title: String
  let summary: String
  let body: String
}

/// Classification result — produced by FM inference, applied to Entry on background actor.
nonisolated struct ClassificationResult: Sendable {
  let entryID: Int
  let categoryLabels: [String]
  let storyKey: String
  let detectedLanguage: String
}

/// Category definition — read from SwiftData, passed to classification as Sendable.
nonisolated struct CategoryDefinition: Sendable {
  let label: String
  let description: String
  let parentLabel: String?
  let isTopLevel: Bool
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
  return result.isEmpty ? ["other"] : result
}

// MARK: - DataWriter Actor

/// Background actor that owns all SwiftData write operations.
/// All data pre-computation (HTML stripping, date formatting) happens here, never on MainActor.
@ModelActor
actor DataWriter {
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
      entry.formattedDate = formatEntryDate(dto.published)
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
      entry.formattedDate = formatEntryDate(dto.published)
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
      }
    }
    try modelContext.save()
  }

  // MARK: - Classification

  func fetchUnclassifiedInputs() throws -> [ClassificationInput] {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { !$0.isClassified },
      sortBy: [SortDescriptor(\Entry.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor).map { entry in
      ClassificationInput(
        entryID: entry.feedbinEntryID,
        title: entry.title ?? "Untitled",
        summary: entry.summary ?? "",
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
        isTopLevel: cat.isTopLevel
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
    entry.primaryCategory = labels.first ?? "other"
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
      if let category = try modelContext.fetch(descriptor).first {
        category.sortOrder = sortOrder
      }
    }
    try modelContext.save()
  }

  func updateCategoryHierarchy(label: String, parentLabel: String?, depth: Int, isTopLevel: Bool, sortOrder: Int) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    category.parentLabel = parentLabel
    category.depth = depth
    category.isTopLevel = isTopLevel
    category.sortOrder = sortOrder
    try modelContext.save()
  }

  func updateCategoryFields(label: String, displayName: String, description: String) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    category.displayName = displayName
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
