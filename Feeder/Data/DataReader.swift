import Foundation
import SwiftData
import os.signpost

// MARK: - DataReader Actor

/// Background actor that owns the read-only SwiftData queries behind the
/// article list and the sidebar unread badges. Its second read-only
/// `ModelContext` sits on the same container as `DataWriter` and the SwiftUI
/// main context, so `PersistentIdentifier`s stay resolvable through
/// `model(for:)` on the render and selection path, and its own actor keeps a
/// read from queuing behind the writer's backlog (`STACK.md § 14`).
///
/// Read-only by contract: zero `insert`, zero `save`, `autosaveEnabled =
/// false`. A `ModelContext` fetch includes the context's pending changes, so a
/// stray write here would leak uncommitted state into results. Only `Sendable`
/// DTOs and `[PersistentIdentifier]` leave the actor; no `@Model` crosses the
/// boundary (`STACK.md § 0 → Actor boundaries`).
///
/// A read sees a writer's committed `save()` on its next fetch. Rows are
/// snapshots of committed state, and freshness is bounded by the refresh-bump
/// pipeline in `ContentView`, never by this actor.
actor DataReader: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    // Own executor instance: `DefaultSerialModelExecutor` would run the reader
    // on the main thread, and sharing the writer's instance would re-serialise
    // reads behind writes (`STACK.md § 14`).
    self.modelExecutor = BackgroundSerialModelExecutor(
      modelContext: context, queueLabel: "com.feeder.datareader")
  }

  /// Construct a `DataReader` on a detached background task: the init must
  /// happen off the main thread (`STACK.md § 0 → Actor boundaries`).
  static func makeDetached(modelContainer: ModelContainer) async -> DataReader {
    await Task.detached(priority: .utility) {
      DataReader(modelContainer: modelContainer)
    }.value
  }

  // MARK: - Article list (background-fetched section snapshots)

  /// The shared eligibility rule for the unread sidebar badges and the unread
  /// article list: classified, unread, published on or after `cutoffDate`.
  ///
  /// `fetchUnreadCountsSnapshot` uses it verbatim; `fetchEntrySections`
  /// composes the same three clauses alongside its per-axis, `showRead`, and
  /// pinned-entry clauses. The two fetchers must agree on the eligible row set
  /// whenever `showRead == false`, which is the only shape the sidebar counts.
  static func unreadEligiblePredicate(cutoffDate: Date) -> Predicate<Entry> {
    #Predicate<Entry> {
      $0.isClassified && $0.isRead == false && $0.publishedAt >= cutoffDate
    }
  }

  /// Fetch entries for an article-list selection, project them into
  /// `EntryRowDTO` snapshots, and group them by calendar day. Fetch,
  /// projection, grouping, and aggregate flattening all run on this actor, so
  /// MainActor renders the sections without touching the store. Pass either
  /// `category` or `folder`; both nil returns an empty result.
  ///
  /// `window` has no default, so every call site states its paging intent. The
  /// three modes share one predicate core and one sort, and differ only in the
  /// keyset clause `entryListDescriptor` builds — never `fetchOffset`, never
  /// in-Swift filtering (`STACK.md § 7`). `firstPage` grows to cover the
  /// pinned row's sort position, so the selected row never falls outside the
  /// window.
  func fetchEntrySections(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinnedFeedbinEntryID: Int? = nil, window: EntryListWindow
  ) throws -> EntryListFetchResult {
    // `BackgroundSerialModelExecutor` must keep this read off the main thread.
    dispatchPrecondition(condition: .notOnQueue(.main))
    // Kill queued stale fetches before they touch the store: under rapid J/K
    // the serial reader mailbox accumulates fetches whose owning `.task` a
    // structural-key change already cancelled. Actor methods run in the
    // caller's task, so this observes that cancellation, and checking it
    // before the signpost keeps aborted fetches out of the interval stats.
    try Task.checkCancellation()
    // The end message carries the paging mode and row count, so a trace can
    // split first-page, append, and refresh cost. Counts only, no user-derived
    // labels (`STACK.md § 8`).
    let modeLabel: String
    switch window {
    case .firstPage: modeLabel = "first"
    case .atOrAbove: modeLabel = "above"
    case .after: modeLabel = "after"
    }
    var fetchedRowCount = 0
    let signpost = perfSignposter.beginInterval(PerformanceSignpostName.readFetchSections)
    defer {
      perfSignposter.endInterval(
        PerformanceSignpostName.readFetchSections, signpost,
        "mode=\(modeLabel, privacy: .public) rows=\(fetchedRowCount, privacy: .public)")
    }
    // `pinnedFeedbinEntryID` keeps the selected row visible when its `isRead`
    // flips out of the filter. The 0 sentinel is safe — Feedbin assigns
    // positive entry IDs only.
    let pinned = pinnedFeedbinEntryID ?? 0
    // `firstPage` is an `after` fetch from a top sentinel cursor, so the first
    // page and its appends tile by construction: one clause family, no seam to
    // disagree on. `atOrAbove` is unbounded above the cursor and bounded by
    // how far the user has grown the window.
    let cursor: EntryListCursor
    let pageLimit: Int?
    let usesAfterClause: Bool
    switch window {
    case .firstPage(let limit):
      cursor = EntryListCursor(publishedAt: .distantFuture, feedbinEntryID: Int.max)
      pageLimit = limit
      usesAfterClause = true
    case .after(let pageCursor, let limit):
      cursor = pageCursor
      pageLimit = limit
      usesAfterClause = true
    case .atOrAbove(let windowCursor):
      cursor = windowCursor
      pageLimit = nil
      usesAfterClause = false
    }
    guard
      var descriptor = entryListDescriptor(
        category: category, folder: folder, showRead: showRead, cutoffDate: cutoffDate,
        pinned: pinned, cursor: cursor, usesAfterClause: usesAfterClause)
    else { return .empty }
    if let pageLimit {
      // Fetch one row past the window and drop it below, so `hasMore` needs no
      // COUNT query and cannot report a false positive at a full page.
      descriptor.fetchLimit = pageLimit + 1
    }
    // Hydrate only the columns `projectEntryRow` reads. `plainText` is
    // excluded on purpose: it is the full article body, and the projection
    // faults it per-row, off-main, only when `summaryPlainText` is empty.
    // Prefetching `feed` in the same fetch keeps the favicon key and the
    // fallback initial free of a per-row relationship fault.
    descriptor.propertiesToFetch = [
      \.feedbinEntryID, \.title, \.formattedPublishedTime, \.displayDomain,
      \.summaryPlainText, \.isRead, \.publishedAt,
    ]
    descriptor.relationshipKeyPathsForPrefetching = [\.feed]
    var entries = try modelContext.fetch(descriptor)
    var effectiveLimit = pageLimit
    // A bare first page can exclude the pinned row. Grow the window to the
    // pin's sort position and refetch the grown prefix once: chronology stays
    // continuous, and the pin is never unioned out-of-band, which would render
    // a timeline gap. Only `firstPage` grows — appends tile below an already
    // covered window, and `atOrAbove` refetches a window that covered the pin.
    if case .firstPage(let requestedLimit) = window, pinned > 0,
      !entries.contains(where: { $0.feedbinEntryID == pinned }),
      let coveringLimit = try pinCoveringLimit(
        category: category, folder: folder, showRead: showRead,
        cutoffDate: cutoffDate, pinned: pinned, requested: requestedLimit),
      coveringLimit > requestedLimit
    {
      effectiveLimit = coveringLimit
      descriptor.fetchLimit = coveringLimit + 1
      entries = try modelContext.fetch(descriptor)
    }
    var hasMore = false
    if let effectiveLimit, entries.count > effectiveLimit {
      hasMore = true
      entries.removeLast(entries.count - effectiveLimit)
    }
    // The fetch is the dominant cost; re-check before paying for projection
    // and grouping when the consuming task is already gone.
    try Task.checkCancellation()
    let rows = entries.map { projectEntryRow($0) }
    fetchedRowCount = rows.count
    // `atOrAbove` has no limit to overshoot, so probe for rows below the
    // returned window with one `after(lastRow, limit: 1)` fetch and keep
    // `hasMore` exact across refreshes.
    if case .atOrAbove = window, let lastRow = rows.last {
      hasMore = try hasRowsBelow(
        category: category, folder: folder, showRead: showRead, cutoffDate: cutoffDate,
        pinned: pinned,
        cursor: EntryListCursor(
          publishedAt: lastRow.publishedAt, feedbinEntryID: lastRow.feedbinEntryID))
    }
    let sections = groupRowsByDay(rows)
    // `sections` and `rows` share the sort order, so one pass over `rows`
    // produces the identifier sequence the sections carry.
    return EntryListFetchResult(
      sections: sections,
      allEntryIDs: rows.map(\.persistentID),
      distinctFeedIDs: Set(rows.compactMap(\.feedFeedbinID)),
      renderedUnreadFeedbinEntryIDs: Set(rows.lazy.filter { !$0.isRead }.map(\.feedbinEntryID)),
      hasMore: hasMore
    )
  }

  /// The one builder for every article-list descriptor: the eligibility core
  /// composed with one of the two keyset clauses. Four `#Predicate` literals,
  /// because `#Predicate` cannot compose sub-predicates — this clause pair is
  /// the single place the keyset ordering rule lives:
  /// - after(C):     `publishedAt < C.date OR (== AND feedbinEntryID < C.id)`
  /// - atOrAbove(C): `publishedAt > C.date OR (== AND feedbinEntryID >= C.id)`
  /// The two partition the sorted result exactly at C, so pages tile with no
  /// duplicate and no skip. Returns nil when neither axis is set.
  private func entryListDescriptor(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinned: Int, cursor: EntryListCursor, usesAfterClause: Bool
  ) -> FetchDescriptor<Entry>? {
    // The secondary sort on `feedbinEntryID` keeps the order deterministic when
    // two entries share a `publishedAt`. Without it, equal-timestamp rows can
    // swap between fetches, which defeats the `Equatable` diff skip in
    // `EntryListView` and reshuffles the list. The keyset clauses break ties on
    // the same key, so page seams stay deterministic through such a run.
    let entrySort: [SortDescriptor<Entry>] = [
      SortDescriptor(\Entry.publishedAt, order: .reverse),
      SortDescriptor(\Entry.feedbinEntryID, order: .reverse),
    ]
    let cursorDate = cursor.publishedAt
    let cursorID = cursor.feedbinEntryID
    if let category {
      if usesAfterClause {
        return FetchDescriptor<Entry>(
          predicate: #Predicate<Entry> {
            $0.isClassified && $0.primaryCategory == category
              && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
              && $0.publishedAt >= cutoffDate
              && ($0.publishedAt < cursorDate
                || ($0.publishedAt == cursorDate && $0.feedbinEntryID < cursorID))
          },
          sortBy: entrySort
        )
      }
      return FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryCategory == category
            && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
            && $0.publishedAt >= cutoffDate
            && ($0.publishedAt > cursorDate
              || ($0.publishedAt == cursorDate && $0.feedbinEntryID >= cursorID))
        },
        sortBy: entrySort
      )
    }
    if let folder {
      if usesAfterClause {
        return FetchDescriptor<Entry>(
          predicate: #Predicate<Entry> {
            $0.isClassified && $0.primaryFolder == folder
              && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
              && $0.publishedAt >= cutoffDate
              && ($0.publishedAt < cursorDate
                || ($0.publishedAt == cursorDate && $0.feedbinEntryID < cursorID))
          },
          sortBy: entrySort
        )
      }
      return FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryFolder == folder
            && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
            && $0.publishedAt >= cutoffDate
            && ($0.publishedAt > cursorDate
              || ($0.publishedAt == cursorDate && $0.feedbinEntryID >= cursorID))
        },
        sortBy: entrySort
      )
    }
    return nil
  }

  /// Exact `hasMore` probe for the `atOrAbove` refresh: one `after(lastRow,
  /// limit: 1)` fetch through the same descriptor builder. A non-empty result
  /// means the store holds an eligible row below the returned window.
  private func hasRowsBelow(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinned: Int, cursor: EntryListCursor
  ) throws -> Bool {
    guard
      var probe = entryListDescriptor(
        category: category, folder: folder, showRead: showRead, cutoffDate: cutoffDate,
        pinned: pinned, cursor: cursor, usesAfterClause: true)
    else { return false }
    probe.fetchLimit = 1
    probe.propertiesToFetch = [\.feedbinEntryID]
    return try !modelContext.fetch(probe).isEmpty
  }

  /// Smallest window that keeps the pinned row inside the first page. Returns
  /// nil when the pinned row is missing or ineligible for this context, so
  /// there is nothing to cover.
  ///
  /// The by-key lookup reads a few unlisted columns off one row, off-main —
  /// the sanctioned exception scale. The pin's 1-based position in the sorted
  /// result is the count of rows at or above its key, so the count reuses the
  /// `atOrAbove` clause family and position counting can never disagree with
  /// window fetching on the ordering rule.
  private func pinCoveringLimit(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinned: Int, requested: Int
  ) throws -> Int? {
    var pinDescriptor = FetchDescriptor<Entry>(
      predicate: #Predicate<Entry> { $0.feedbinEntryID == pinned })
    pinDescriptor.fetchLimit = 1
    pinDescriptor.propertiesToFetch = [
      \.feedbinEntryID, \.publishedAt, \.isClassified, \.primaryCategory, \.primaryFolder,
    ]
    guard let pin = try modelContext.fetch(pinDescriptor).first else { return nil }
    guard pin.isClassified, pin.publishedAt >= cutoffDate else { return nil }
    if let category, pin.primaryCategory != category { return nil }
    if let folder, pin.primaryFolder != folder { return nil }
    guard
      let positionDescriptor = entryListDescriptor(
        category: category, folder: folder, showRead: showRead, cutoffDate: cutoffDate,
        pinned: pinned,
        cursor: EntryListCursor(
          publishedAt: pin.publishedAt, feedbinEntryID: pin.feedbinEntryID),
        usesAfterClause: false)
    else { return nil }
    let position = try modelContext.fetchCount(positionDescriptor)
    guard position > 0 else { return nil }
    return effectiveRowLimit(requested: requested, pinPosition: position)
  }

  /// Project one fetched `Entry` into its `Sendable` row snapshot, on this
  /// background actor.
  ///
  /// The projection may touch only the columns listed in
  /// `fetchEntrySections`' `propertiesToFetch` plus the prefetched `feed`
  /// relationship: any unlisted property fires a per-row SQLite fault. The one
  /// sanctioned exception is `plainText`, faulted here, off-main, only when
  /// `summaryPlainText` is empty.
  private func projectEntryRow(_ entry: Entry) -> EntryRowDTO {
    let summary = entry.summaryPlainText
    let feed = entry.feed
    // `extractDomain` stores "" when the URL has no host, so a row with no
    // domain reaches the DTO as `nil` in every case; the row reserves the
    // domain line with a placeholder only for `nil`.
    let displayDomain = entry.displayDomain.flatMap { $0.isEmpty ? nil : $0 }
    return EntryRowDTO(
      persistentID: entry.persistentModelID,
      feedbinEntryID: entry.feedbinEntryID,
      title: entry.title,
      formattedPublishedTime: entry.formattedPublishedTime,
      displayDomain: displayDomain,
      excerpt: rowExcerpt(
        summaryPlainText: summary,
        plainText: summary.isEmpty ? entry.plainText : ""
      ),
      isRead: entry.isRead,
      publishedAt: entry.publishedAt,
      feedFeedbinID: feed?.feedbinFeedID,
      feedInitial: feedInitial(from: feed?.title)
    )
  }

  // MARK: - Favicons

  /// Fetch favicon blobs for the given feeds in one background query.
  /// `propertiesToFetch` limits hydration to the key and blob columns. Returns
  /// only feeds that have data; a missing key is `FaviconStore`'s
  /// negative-cache signal.
  func fetchFaviconData(feedbinFeedIDs: Set<Int>) throws -> [Int: Data] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard !feedbinFeedIDs.isEmpty else { return [:] }
    let ids = Array(feedbinFeedIDs)
    var descriptor = FetchDescriptor<Feed>(
      predicate: #Predicate<Feed> { ids.contains($0.feedbinFeedID) }
    )
    descriptor.propertiesToFetch = [\.feedbinFeedID, \.faviconData]
    let feeds = try modelContext.fetch(descriptor)
    var faviconData: [Int: Data] = [:]
    for feed in feeds {
      if let data = feed.faviconData { faviconData[feed.feedbinFeedID] = data }
    }
    return faviconData
  }

  // MARK: - Unread aggregation

  /// Precompute per-category and per-folder unread counts plus the underlying
  /// ID sets in one streaming fetch. The resulting `UnreadCountsSnapshot` is
  /// the only input the sidebar needs for its badges.
  ///
  /// The predicate mirrors `fetchEntrySections`, so badges and lists count the
  /// same rows: without the cutoff clause an entry between `articleKeepDays`
  /// and `maxRetentionAge` would be counted in the sidebar but hidden from the
  /// list. `enumerate(_:batchSize:)` hydrates in chunks instead of
  /// materialising the whole unread universe, and `propertiesToFetch` keeps
  /// the fault handler off the large columns.
  func fetchUnreadCountsSnapshot(cutoffDate: Date) throws -> UnreadCountsSnapshot {
    // This aggregation materialises the unread universe;
    // `BackgroundSerialModelExecutor` must keep it off the main thread.
    dispatchPrecondition(condition: .notOnQueue(.main))
    var descriptor = FetchDescriptor<Entry>(
      predicate: Self.unreadEligiblePredicate(cutoffDate: cutoffDate)
    )
    descriptor.propertiesToFetch = [\.feedbinEntryID, \.primaryCategory, \.primaryFolder]

    var categoryCounts: [String: Int] = [:]
    var folderCounts: [String: Int] = [:]
    var unreadFeedbinEntryIDs: Set<Int> = []
    var unreadIDByCategory: [String: Set<Int>] = [:]
    var unreadIDByFolder: [String: Set<Int>] = [:]
    var totalUnread = 0

    try modelContext.enumerate(descriptor, batchSize: 500) { entry in
      let id = entry.feedbinEntryID
      let category = entry.primaryCategory
      let folder = entry.primaryFolder
      unreadFeedbinEntryIDs.insert(id)
      totalUnread += 1
      if !category.isEmpty {
        categoryCounts[category, default: 0] += 1
        unreadIDByCategory[category, default: []].insert(id)
      }
      if !folder.isEmpty {
        folderCounts[folder, default: 0] += 1
        unreadIDByFolder[folder, default: []].insert(id)
      }
    }

    return UnreadCountsSnapshot(
      categoryCounts: categoryCounts,
      folderCounts: folderCounts,
      unreadFeedbinEntryIDs: unreadFeedbinEntryIDs,
      unreadIDByCategory: unreadIDByCategory,
      unreadIDByFolder: unreadIDByFolder,
      totalUnread: totalUnread
    )
  }
}
