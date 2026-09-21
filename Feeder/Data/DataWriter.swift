import Foundation
import OSLog
import SwiftData

// MARK: - Bootstrap

/// Outcome of `DataWriter.bootstrap()`. The action discriminates the two
/// legitimate startup paths: steady-state no-op, and first-launch seed of the
/// default taxonomy. Schema migration runs inside the `ModelContainer` open
/// via `FeederMigrationPlan`, never through bootstrap.
nonisolated struct BootstrapOutcome: Sendable, Equatable {
  enum Action: Sendable, Equatable {
    case skipped
    case seeded
  }
  let action: Action
  let feedCount: Int
  let entryCount: Int
  let categoryCount: Int
  let folderCount: Int
}

// MARK: - DataWriter Actor

/// `UserDefaults` key that marks the default taxonomy as seeded for this
/// install. It lives outside the SwiftData store so a custom migration stage
/// that empties the categories table cannot drop or hide it. Only the
/// catastrophic-reopen fallback in `FeederApp.init` clears it.
nonisolated let defaultsSeededUserDefaultsKey = "feeder.defaultsSeeded"

/// Minimal `Sendable` flag store behind the seeded-defaults sentinel.
/// `UserDefaults` is not `Sendable`, so it cannot cross the actor boundary
/// that `makeDetached` requires. Tests inject an isolated in-memory store, so
/// the flag from one test cannot suppress seeding in another.
nonisolated protocol SeededDefaultsFlagStore: Sendable {
  func isSeeded(forKey key: String) -> Bool
  func setSeeded(_ value: Bool, forKey key: String)
}

/// Production implementation over the live `UserDefaults.standard` suite.
/// Every call re-resolves the suite instead of capturing the non-`Sendable`
/// reference, which keeps the wrapper itself `Sendable`.
nonisolated struct StandardUserDefaultsFlagStore: SeededDefaultsFlagStore {
  func isSeeded(forKey key: String) -> Bool {
    UserDefaults.standard.bool(forKey: key)
  }
  func setSeeded(_ value: Bool, forKey key: String) {
    UserDefaults.standard.set(value, forKey: key)
  }
}

/// Background actor that owns every SwiftData write. All data pre-computation
/// — HTML stripping, date formatting — happens here, never on MainActor.
///
/// Off-main execution comes from the custom `BackgroundSerialModelExecutor`
/// binding, not from the `ModelActor` conformance: `DefaultSerialModelExecutor`
/// only serialises context access and runs on the awaiting caller's thread,
/// which is main for every MainActor call site (`STACK.md § 14`). Every
/// actor-isolated method asserts the off-main invariant.
actor DataWriter: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer
  /// Flag store behind the seeded-defaults sentinel. `Sendable`, so it crosses
  /// the `Task.detached` boundary in `makeDetached`.
  nonisolated let defaultsFlagStore: any SeededDefaultsFlagStore

  init(
    modelContainer: ModelContainer,
    defaultsFlagStore: any SeededDefaultsFlagStore = StandardUserDefaultsFlagStore()
  ) {
    self.modelContainer = modelContainer
    self.defaultsFlagStore = defaultsFlagStore
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    // Own executor instance: `DefaultSerialModelExecutor` would run a write on
    // the caller's thread, and sharing the reader's instance would re-serialise
    // reads behind writes (`STACK.md § 14`).
    self.modelExecutor = BackgroundSerialModelExecutor(
      modelContext: context, queueLabel: "com.feeder.datawriter")
  }

  private static let logger = Logger(subsystem: "com.feeder.app", category: "DataWriter")

  // MARK: - Bootstrap

  /// Construct a `DataWriter` on a detached background task: the init must
  /// happen off the main thread (`STACK.md § 0 → Actor boundaries`).
  static func makeDetached(
    modelContainer: ModelContainer,
    defaultsFlagStore: any SeededDefaultsFlagStore = StandardUserDefaultsFlagStore()
  ) async -> DataWriter {
    await Task.detached(priority: .utility) {
      DataWriter(modelContainer: modelContainer, defaultsFlagStore: defaultsFlagStore)
    }.value
  }

  /// Reconcile the persistent store on launch.
  ///
  /// Three legitimate paths:
  /// - Seeded flag present → `.skipped`, whether or not the user has since
  ///   deleted default categories.
  /// - Seeded flag absent but `Category` rows exist → set the flag, then
  ///   `.skipped`. Re-seeding would let the `@Attribute(.unique) label` upsert
  ///   overwrite the user's edits on every default-labelled row.
  /// - Seeded flag absent and the categories table empty → seed the default
  ///   folders, categories, and the system `uncategorized` fallback, set the
  ///   flag, then `.seeded`.
  ///
  /// Every ingested article must keep its category assignment across schema
  /// bumps (`VISION.md → Core Principles`), so the flag lives outside the
  /// store and a migration that empties the categories table cannot trigger a
  /// re-seed.
  func bootstrap() throws -> BootstrapOutcome {
    // `BackgroundSerialModelExecutor` must keep every write off the main
    // thread. Asserted at the top of every actor-isolated method here
    // (`STACK.md § 5`).
    dispatchPrecondition(condition: .notOnQueue(.main))
    let action: BootstrapOutcome.Action

    if defaultsFlagStore.isSeeded(forKey: defaultsSeededUserDefaultsKey) {
      action = .skipped
    } else if try modelContext.fetchCount(FetchDescriptor<Category>()) > 0 {
      // A store written without the sentinel reaches this branch with the
      // flag absent and taxonomy present. Infer "already seeded" from the
      // `Category` rows and set the flag, or the `@Attribute(.unique) label`
      // upsert would overwrite the user's edits on every default-labelled
      // row. A new install hits neither branch and seeds below.
      defaultsFlagStore.setSeeded(true, forKey: defaultsSeededUserDefaultsKey)
      action = .skipped
    } else {
      try seedDefaultTaxonomy()
      try modelContext.save()
      defaultsFlagStore.setSeeded(true, forKey: defaultsSeededUserDefaultsKey)
      action = .seeded
    }

    return BootstrapOutcome(
      action: action,
      feedCount: try modelContext.fetchCount(FetchDescriptor<Feed>()),
      entryCount: try modelContext.fetchCount(FetchDescriptor<Entry>()),
      categoryCount: try modelContext.fetchCount(FetchDescriptor<Category>()),
      folderCount: try modelContext.fetchCount(FetchDescriptor<Folder>())
    )
  }

  /// Insert default folders, categories, and the system `uncategorized`
  /// fallback. Does not save — callers control the transaction boundary.
  private func seedDefaultTaxonomy() throws {
    for folder in DefaultCategoryData.folders {
      modelContext.insert(
        Folder(label: folder.label, displayName: folder.displayName, sortOrder: folder.sortOrder)
      )
    }
    for category in DefaultCategoryData.categories {
      modelContext.insert(
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
    modelContext.insert(
      Category(
        label: uncategorizedLabel,
        displayName: "Uncategorized",
        categoryDescription: "Use only when no other category clearly matches.",
        sortOrder: Int.max,
        isSystem: true
      )
    )
  }

  // MARK: - Feed persistence

  func syncFeeds(_ subscriptions: [FeedbinSubscription]) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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

  private func resolveIconMapping(_ icons: [FeedbinIcon]) throws -> ([String: String], [Feed]) {
    let iconsByHost = Dictionary(icons.map { ($0.host, $0.url) }, uniquingKeysWith: { first, _ in first })
    let feeds = try modelContext.fetch(FetchDescriptor<Feed>())
    return (iconsByHost, feeds)
  }

  private func matchIconURL(feed: Feed, iconsByHost: [String: String]) -> String? {
    guard let host = URL(string: feed.siteURL)?.host() else { return nil }
    let lookupHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return iconsByHost[lookupHost] ?? iconsByHost[host]
  }

  // MARK: - Entry persistence

  /// Insert newly synced entries. An existing row is skipped, never
  /// re-written.
  ///
  /// IMMUTABILITY INVARIANT: because existing rows are skipped, a persisted
  /// row's `(publishedAt, feedbinEntryID)` pair — the `EntryListCursor` sort
  /// key — never mutates, and keyset pages tile exactly only under that
  /// invariant. If this method ever starts updating existing rows, it must not
  /// touch `publishedAt` or `feedbinEntryID`.
  func persistEntries(_ entries: [FeedbinEntry], unreadIDs: Set<Int>) throws -> Int {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    Self.logger.info("Marked \(markedIDs.count) entries as read in \(target.logDescription)")
    return markedIDs
  }

  // MARK: - Extracted content

  func fetchExtractedContentRequests() throws -> [(entryID: Int, url: String)] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.extractedContentURL != nil && $0.extractedContent == nil }
    )
    return try modelContext.fetch(descriptor).compactMap { entry in
      guard let url = entry.extractedContentURL else { return nil }
      return (entryID: entry.feedbinEntryID, url: url)
    }
  }

  func applyExtractedContent(results: [(entryID: Int, content: String)]) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
        // `EntryDetailView` decodes via `.task(id: entry.articleBlocksData)`,
        // so this write needs no view-level cache invalidation.
      }
    }
    try modelContext.save()
  }

  // `DataWriter` keeps only writes and the intra-write reads that must see
  // pending changes. The article-list and unread-aggregation reads live on
  // `DataReader`, so they never queue behind a long write here.

  // MARK: - Classification

  /// Shared predicate for "not yet classified, inside the retention window".
  /// `countUnclassifiedEntries` and `fetchUnclassifiedInputs` compose it
  /// verbatim, so the progress denominator and the work the runner drains can
  /// never disagree about which rows are pending.
  static func unclassifiedPredicate(cutoffDate: Date) -> Predicate<Entry> {
    #Predicate<Entry> { !$0.isClassified && $0.publishedAt >= cutoffDate }
  }

  /// SQLite-level count of pending-classification rows, behind the live
  /// "Categorizing Y/X" denominator. `fetchCount` runs the aggregate in
  /// SQLite, so no `Entry` is materialised and the call stays cheap enough for
  /// chunk-boundary cadence (`STACK.md § 4`).
  func countUnclassifiedEntries(cutoffDate: Date) throws -> Int {
    dispatchPrecondition(condition: .notOnQueue(.main))
    return try modelContext.fetchCount(
      FetchDescriptor<Entry>(predicate: Self.unclassifiedPredicate(cutoffDate: cutoffDate))
    )
  }

  /// Fetch up to `limit` pending-classification inputs, newest first. `limit`
  /// is required: materialising the whole backlog hydrates every pending row's
  /// `plainText` at once, which risks the memory ceiling on a large first sync
  /// (`STACK.md § 4`). The `createdAt`-descending sort classifies the most
  /// recently ingested entries first.
  func fetchUnclassifiedInputs(cutoffDate: Date, limit: Int) throws -> [ClassificationInput] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    var descriptor = FetchDescriptor<Entry>(
      predicate: Self.unclassifiedPredicate(cutoffDate: cutoffDate),
      sortBy: [SortDescriptor(\Entry.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { entry in entry.feedbinEntryID == entryID }
    )
    guard let entry = try modelContext.fetch(descriptor).first else { return }

    let categories = try fetchCategoryDefinitions()
    let validLabels = Set(categories.map(\.label))
    let label = validLabels.contains(result.categoryLabel) ? result.categoryLabel : uncategorizedLabel

    try Task.checkCancellation()
    entry.isClassified = true
    entry.primaryCategory = label
    entry.primaryFolder = categories.first { $0.label == label }?.folderLabel ?? ""
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
  }

  func resetClassification() throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Entry>()
    let entries = try modelContext.fetch(descriptor)
    // The reset is atomic with respect to cancellation once mutations start.
    try Task.checkCancellation()
    for entry in entries {
      entry.isClassified = false
      entry.primaryCategory = ""
      entry.primaryFolder = ""
    }
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw error
    }
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
    dispatchPrecondition(condition: .notOnQueue(.main))
    let folder = Folder(label: label, displayName: displayName, sortOrder: sortOrder)
    modelContext.insert(folder)
    try modelContext.save()
  }

  func deleteFolder(label: String) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
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

    // Cover the folder's current categories and the orphaned entries left by
    // deleted ones.
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
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Folder>(
      predicate: #Predicate<Folder> { $0.label == label }
    )
    guard let folder = try modelContext.fetch(descriptor).first else { return }
    folder.displayName = displayName
    try modelContext.save()
  }

  func fetchFolderSortOrder(label: String) throws -> Int? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Folder>(
      predicate: #Predicate<Folder> { $0.label == label }
    )
    return try modelContext.fetch(descriptor).first?.sortOrder
  }

  /// Re-assign `sortOrder` for top-level folders to match each label's
  /// position in `orderedLabels`. A label missing from the store is skipped, so
  /// the writer tolerates a stale UI snapshot. `[String]` is `Sendable`; no
  /// `Folder` crosses the actor boundary.
  func reorderFolders(orderedLabels: [String]) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    for (index, label) in orderedLabels.enumerated() {
      let descriptor = FetchDescriptor<Folder>(
        predicate: #Predicate<Folder> { $0.label == label }
      )
      guard let folder = try modelContext.fetch(descriptor).first else { continue }
      folder.sortOrder = index
    }
    try modelContext.save()
  }

  // MARK: - Category management

  func addCategory(label: String, displayName: String, description: String, sortOrder: Int, folderLabel: String? = nil) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    guard !category.isSystem else { return }
    modelContext.delete(category)
    try modelContext.save()
  }

  /// Count entries assigned to a category. The management UI shows the
  /// recategorize confirmation only when the count is non-zero. The predicate
  /// runs at SQLite level, so no row is materialised here.
  func countEntries(primaryCategoryLabel label: String) throws -> Int {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.primaryCategory == label }
    )
    return try modelContext.fetchCount(descriptor)
  }

  /// Reassign every entry whose `primaryCategory == sourceLabel` to
  /// `targetLabel` and the target's folder, then delete the source category.
  /// The reassignment loop and the delete run inside
  /// `ModelContext.transaction(block:)`, so a save-time failure leaves the
  /// store byte-equivalent to its pre-call state. The pre-flight guards run
  /// before the transaction opens, so they short-circuit with no pending
  /// mutation to roll back.
  ///
  /// Errors:
  /// - `.sourceMissing` — no category with `sourceLabel` exists.
  /// - `.targetMissing` — no category with `targetLabel` exists.
  /// - `.sourceEqualsTarget` — refuses to delete the category the caller asked
  ///   to keep its articles in.
  /// - `.sourceIsSystem` — the built-in `uncategorized` cannot be removed.
  func removeCategoryAndReassignArticles(
    _ sourceLabel: String, to targetLabel: String
  ) throws -> RecategorizeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard sourceLabel != targetLabel else {
      throw CategoryReassignError.sourceEqualsTarget
    }
    let sourceDescriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == sourceLabel }
    )
    guard let source = try modelContext.fetch(sourceDescriptor).first else {
      throw CategoryReassignError.sourceMissing
    }
    guard !source.isSystem else {
      throw CategoryReassignError.sourceIsSystem
    }
    let targetDescriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == targetLabel }
    )
    guard let target = try modelContext.fetch(targetDescriptor).first else {
      throw CategoryReassignError.targetMissing
    }
    let targetFolderLabel = target.folderLabel ?? ""

    let entryDescriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.primaryCategory == sourceLabel }
    )
    let affected = try modelContext.fetch(entryDescriptor)
    // `transaction(block:)` commits at the closing brace and rolls back on any
    // throw, so do not call `save()` afterwards. Either every entry moves and
    // the source is gone, or nothing changed.
    try modelContext.transaction {
      for entry in affected {
        entry.primaryCategory = targetLabel
        entry.primaryFolder = targetFolderLabel
      }
      modelContext.delete(source)
    }
    Self.logger.info(
      "Reassigned \(affected.count) entries from category \(sourceLabel, privacy: .public) to \(targetLabel, privacy: .public), then removed the source category."
    )
    return RecategorizeOutcome(
      reassignedCount: affected.count,
      targetFolderLabel: targetFolderLabel
    )
  }

  func fetchCategorySortOrder(label: String) throws -> Int? {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    return try modelContext.fetch(descriptor).first?.sortOrder
  }

  func moveCategoryToFolder(label: String, folderLabel: String?, sortOrder: Int) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first, !category.isSystem else { return }
    category.folderLabel = folderLabel
    category.sortOrder = sortOrder
    try updatePrimaryFolderOnEntries(categoryLabel: label, newFolder: folderLabel ?? "")
    try modelContext.save()
  }

  /// Re-assign `sortOrder` for the categories in one folder, or at root when
  /// `folderLabel` is `nil`, to match each label's position in
  /// `orderedLabels`. A label missing from `orderedLabels` is left untouched,
  /// and system categories are skipped so `uncategorized` cannot be reordered
  /// into another slot. `[String]` is `Sendable`; no `Category` crosses the
  /// actor boundary.
  func reorderCategories(inFolder folderLabel: String?, orderedLabels: [String]) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    for (index, label) in orderedLabels.enumerated() {
      let descriptor = FetchDescriptor<Category>(
        predicate: #Predicate<Category> { $0.label == label }
      )
      guard let category = try modelContext.fetch(descriptor).first,
        !category.isSystem,
        category.folderLabel == folderLabel
      else { continue }
      category.sortOrder = index
    }
    try modelContext.save()
  }

  func updateSystemFlag(label: String, isSystem: Bool) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let descriptor = FetchDescriptor<Category>(
      predicate: #Predicate<Category> { $0.label == label }
    )
    guard let category = try modelContext.fetch(descriptor).first else { return }
    category.isSystem = isSystem
    try modelContext.save()
  }

  func updateCategoryFields(label: String, displayName: String, description: String) throws {
    dispatchPrecondition(condition: .notOnQueue(.main))
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
    dispatchPrecondition(condition: .notOnQueue(.main))
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

  /// Delete entries whose `publishedAt` is older than `days` ago, so the store
  /// does not grow without bound. The cutoff is raw seconds, with no calendar
  /// boundary, exactly as `articleCutoffDate()` and `maxRetentionAge` compute
  /// theirs, so the purge window stays consistent with the read-side
  /// predicates.
  ///
  /// The day count is the parameter, not a `Date`, so no call site recomputes
  /// retention math. Production callers pass the fixed 30-day ceiling, the
  /// largest value the keep-days picker offers, so changing that setting never
  /// needs a refetch and recategorise round-trip.
  func purgeEntriesOlderThan(_ days: Int) throws -> PurgeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    let descriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.publishedAt < cutoff }
    )
    let old = try modelContext.fetch(descriptor)
    guard !old.isEmpty else { return PurgeOutcome(purgedCount: 0) }
    for entry in old {
      modelContext.delete(entry)
    }
    try modelContext.save()
    Self.logger.info("Purged \(old.count) entries older than \(days) days")
    return PurgeOutcome(purgedCount: old.count)
  }
}
