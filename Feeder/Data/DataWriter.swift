import Foundation
import OSLog
import SwiftData

// MARK: - Entry grouping (lives here because it reads @Model Entry within the actor's context)

/// Group entries by calendar day, preserving sort order, returning Sendable section DTOs.
/// Runs in whatever context calls it (typically `DataWriter` background actor).
/// `Entry` reads are local to that context — no actor hops, no MainActor work.
nonisolated func groupEntriesByDay(_ entries: [Entry]) -> [EntryListSection] {
  let calendar = Calendar.current
  var sections: [EntryListSection] = []
  var currentDay: Date?
  var currentIDs: [PersistentIdentifier] = []

  for entry in entries {
    let day = calendar.startOfDay(for: entry.publishedAt)
    if day != currentDay {
      if let prevDay = currentDay, !currentIDs.isEmpty {
        sections.append(
          EntryListSection(id: prevDay, label: entryListSectionLabel(for: prevDay), entryIDs: currentIDs)
        )
      }
      currentDay = day
      currentIDs = [entry.persistentModelID]
    } else {
      currentIDs.append(entry.persistentModelID)
    }
  }
  if let lastDay = currentDay, !currentIDs.isEmpty {
    sections.append(
      EntryListSection(id: lastDay, label: entryListSectionLabel(for: lastDay), entryIDs: currentIDs)
    )
  }
  return sections
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

  /// Identify icon URLs that need downloading — URL changed or cached data is missing.
  /// Returns the set of distinct icon URLs that need fetching, without modifying any feeds.
  func iconURLsNeedingFetch(_ icons: [FeedbinIcon]) throws -> Set<String> {
    guard !icons.isEmpty else { return [] }
    let (iconsByHost, feeds) = try resolveIconMapping(icons)

    var needed: Set<String> = []
    for feed in feeds {
      if let iconURL = matchIconURL(feed: feed, iconsByHost: iconsByHost),
        feed.faviconURL != iconURL || feed.faviconData == nil
      {
        needed.insert(iconURL)
      }
    }
    return needed
  }

  /// Persist favicon URLs and pre-fetched image data for feeds.
  /// Only updates feeds whose icon URL changed or whose data was missing.
  /// Preserves existing faviconData when the replacement download failed.
  func syncIcons(_ icons: [FeedbinIcon], prefetchedData: [String: Data]) throws {
    guard !icons.isEmpty else { return }
    let (iconsByHost, feeds) = try resolveIconMapping(icons)

    var updated = 0
    for feed in feeds {
      if let iconURL = matchIconURL(feed: feed, iconsByHost: iconsByHost),
        feed.faviconURL != iconURL || feed.faviconData == nil
      {
        feed.faviconURL = iconURL
        if let data = prefetchedData[iconURL] {
          feed.faviconData = data
        }
        updated += 1
      }
    }

    if updated > 0 {
      try modelContext.save()
      Self.logger.info("Updated favicon URLs for \(updated) feeds")
    }
  }

  /// Shared: build icon-host lookup and fetch all feeds once.
  private func resolveIconMapping(_ icons: [FeedbinIcon]) throws -> ([String: String], [Feed]) {
    let iconsByHost = Dictionary(icons.map { ($0.host, $0.url) }, uniquingKeysWith: { first, _ in first })
    let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
    return (iconsByHost, feeds)
  }

  /// Shared: match a feed's site host to an icon URL.
  private func matchIconURL(feed: Feed, iconsByHost: [String: String]) -> String? {
    guard let host = URL(string: feed.siteURL)?.host() else { return nil }
    let lookupHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return iconsByHost[lookupHost] ?? iconsByHost[host]
  }

  // MARK: - Entry persistence

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
      let rawHTML = dto.content ?? dto.summary ?? ""
      let blocks = parseHTMLToBlocks(replaceVideoIframes(rawHTML))
      entry.articleBlocksData = blocks.toJSONData()
      entry.plainText = parseHTMLToBlocks(rawHTML).classificationText
      entry.summaryPlainText = stripHTMLToPlainText(dto.summary ?? "")
      entry.formattedDate = formatEntryDate(dto.published)
      entry.formattedPublishedTime = formatEntryTime(dto.published)

      entry.displayDomain = extractDomain(from: feedsByFeedbinID[dto.feedId]?.siteURL ?? dto.url)
      modelContext.insert(entry)
      newCount += 1
    }

    try modelContext.save()
    return newCount
  }

  // MARK: - Read state

  /// Sync local `isRead` state to match the server's unread-IDs set for every
  /// entry in the store. Returns the number of rows that actually flipped so
  /// callers can tell whether a sync changed anything (cross-device read-state
  /// propagation), not just whether new entries were inserted.
  func updateReadState(unreadIDs: Set<Int>) throws -> Int {
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
    return updatedCount
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

  /// Mark all unread classified entries in a folder or category as read.
  /// Returns the feedbin entry IDs that were flipped from unread → read.
  func markAllAsRead(target: MarkReadTarget, cutoffDate: Date) throws -> Set<Int> {
    let descriptor: FetchDescriptor<Entry>
    switch target {
    case .folder(let label):
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryFolder == label && !$0.isRead
            && $0.publishedAt >= cutoffDate
        }
      )
    case .category(let label):
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryCategory == label && !$0.isRead
            && $0.publishedAt >= cutoffDate
        }
      )
    }
    let entries = try modelContext.fetch(descriptor)
    guard !entries.isEmpty else { return [] }
    var markedIDs = Set<Int>()
    for entry in entries {
      entry.isRead = true
      markedIDs.insert(entry.feedbinEntryID)
    }
    try modelContext.save()
    Self.logger.info("Marked \(markedIDs.count) entries as read for \(String(describing: target))")
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
        let blocks = parseHTMLToBlocks(replaceVideoIframes(content))
        entry.articleBlocksData = blocks.toJSONData()
        entry.plainText = parseHTMLToBlocks(content).classificationText
        entry.invalidateBlocksCache()
      }
    }
    try modelContext.save()
  }

  // MARK: - Article list (background-fetched section snapshots)

  /// Fetch entries for an article list selection and group them by calendar day.
  /// Returns lightweight `EntryListSection` DTOs containing only persistent IDs +
  /// a precomputed section label. The heavy SQLite fetch + Entry materialization
  /// + grouping all happen on this background `ModelActor`, so MainActor stays
  /// free to render the loading state immediately.
  /// Pass either `category` or `folder`; the other should be nil. If both are nil,
  /// returns an empty array.
  func fetchEntrySections(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date
  ) throws -> [EntryListSection] {
    let descriptor: FetchDescriptor<Entry>
    // Secondary sort on feedbinEntryID keeps order deterministic when two entries
    // share the same publishedAt timestamp. Without it, two equal-timestamp rows
    // can swap places between fetches, which defeats the Equatable diff skip in
    // EntryListView.reload() and can cause the list to reshuffle briefly.
    let entrySort: [SortDescriptor<Entry>] = [
      SortDescriptor(\Entry.publishedAt, order: .reverse),
      SortDescriptor(\Entry.feedbinEntryID, order: .reverse),
    ]
    if let category {
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryCategory == category && $0.isRead == showRead
            && $0.publishedAt >= cutoffDate
        },
        sortBy: entrySort
      )
    } else if let folder {
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryFolder == folder && $0.isRead == showRead
            && $0.publishedAt >= cutoffDate
        },
        sortBy: entrySort
      )
    } else {
      return []
    }
    let entries = try modelContext.fetch(descriptor)
    return groupEntriesByDay(entries)
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
        body: entry.plainText,
        url: entry.url
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
        folderLabel: cat.folderLabel,
        keywords: cat.keywords
      )
    }
  }

  func applyClassification(entryID: Int, result: ClassificationResult) throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in entry.feedbinEntryID == entryID }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return }

    let categories = try fetchCategoryDefinitions()
    let validLabels = Set(categories.map(\.label))
    let label = validLabels.contains(result.categoryLabel) ? result.categoryLabel : uncategorizedLabel

    entry.detectedLanguage = result.detectedLanguage
    entry.storyKey = result.storyKey
    entry.isClassified = true
    entry.primaryCategory = label
    entry.primaryFolder = categories.first { $0.label == label }?.folderLabel ?? ""
    try modelContext.save()
  }

  func resetClassification() throws {
    let descriptor = FetchDescriptor<Entry>()
    let entries = try modelContext.fetch(descriptor)
    for entry in entries {
      entry.storyKey = nil
      entry.detectedLanguage = nil
      entry.isClassified = false
      entry.primaryCategory = ""
      entry.primaryFolder = ""
    }
    try modelContext.save()
  }

  // MARK: - Entry folder backfill

  /// Update primaryFolder on all entries assigned to a category when that category's folder changes.
  private func updatePrimaryFolderOnEntries(categoryLabel: String, newFolder: String) throws {
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.primaryCategory == categoryLabel }
    )
    let entries = try modelContext.fetch(descriptor)
    for entry in entries {
      entry.primaryFolder = newFolder
    }
  }

  // MARK: - Folder management

  func addFolder(label: String, displayName: String, sortOrder: Int) throws {
    let folder = Folder(label: label, displayName: displayName, sortOrder: sortOrder)
    modelContext.insert(folder)
    try modelContext.save()
  }

  func deleteFolder(label: String) throws {
    let folderDescriptor = FetchDescriptor<Folder>(
      predicate: #Predicate<Folder> { $0.label == label }
    )
    guard let folder = try modelContext.fetch(folderDescriptor).first else { return }

    // Move categories in this folder to root level with fresh sort orders
    let catDescriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.folderLabel == label }
    )
    let categories = try modelContext.fetch(catDescriptor)
    let existingRootCount = try modelContext.fetchCount(
      FetchDescriptor<Category>(predicate: #Predicate<Category> { $0.folderLabel == nil })
    )
    for (index, category) in categories.enumerated() {
      category.folderLabel = nil
      category.sortOrder = existingRootCount + index
    }

    // Clear primaryFolder on all entries that reference this folder (covers both
    // current categories and orphaned entries from previously deleted categories)
    let entryDescriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.primaryFolder == label }
    )
    let entries = try modelContext.fetch(entryDescriptor)
    for entry in entries {
      entry.primaryFolder = ""
    }

    modelContext.delete(folder)
    try modelContext.save()
  }

  func updateFolderFields(label: String, displayName: String) throws {
    let descriptor = FetchDescriptor<Folder>(
      predicate: #Predicate<Folder> { $0.label == label }
    )
    guard let folder = try modelContext.fetch(descriptor).first else { return }
    folder.displayName = displayName
    try modelContext.save()
  }

  // MARK: - Category management

  func addCategory(label: String, displayName: String, description: String, sortOrder: Int, folderLabel: String? = nil) throws {
    let category = Category(
      label: label,
      displayName: displayName,
      categoryDescription: description,
      sortOrder: sortOrder,
      folderLabel: folderLabel
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
    modelContext.delete(category)
    try modelContext.save()
  }

  func fetchCategorySortOrder(label: String) throws -> Int? {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    return try modelContext.fetch(descriptor).first?.sortOrder
  }

  func moveCategoryToFolder(label: String, folderLabel: String?, sortOrder: Int) throws {
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first, !category.isSystem else { return }
    category.folderLabel = folderLabel
    category.sortOrder = sortOrder
    try updatePrimaryFolderOnEntries(categoryLabel: label, newFolder: folderLabel ?? "")
    try modelContext.save()
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

  func batchUpdateCategoryFolderAndSortOrders(
    folderChanges: [(label: String, folderLabel: String?, sortOrder: Int)],
    sortOrderUpdates: [(label: String, sortOrder: Int)]
  ) throws {
    for change in folderChanges {
      let targetLabel = change.label
      let descriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == targetLabel }
      )
      guard let category = try modelContext.fetch(descriptor).first, !category.isSystem else { continue }
      category.folderLabel = change.folderLabel
      category.sortOrder = change.sortOrder
      try updatePrimaryFolderOnEntries(categoryLabel: change.label, newFolder: change.folderLabel ?? "")
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
    _ definitions: [(label: String, displayName: String, description: String, sortOrder: Int, folderLabel: String?)]
  ) throws {
    for (label, displayName, description, sortOrder, folderLabel) in definitions {
      let category = Category(
        label: label,
        displayName: displayName,
        categoryDescription: description,
        sortOrder: sortOrder,
        folderLabel: folderLabel
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
