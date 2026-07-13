import Foundation
import SwiftData
import os.signpost

// MARK: - DataReader Actor

/// Background actor that owns the read-only SwiftData queries driving the
/// article list and the sidebar unread badges. It mirrors `DataWriter`'s
/// `ModelActor` init idiom, on a SECOND read-only `ModelContext` over the SAME
/// app container (`C_app`) as `DataWriter` and the SwiftUI main context. Being
/// a SEPARATE ACTOR is what fixes the starvation: its reads run on their own
/// actor mailbox / serial executor and are never queued behind the writer
/// actor's backlog of `persistEntries` / classification work. That queuing was
/// the panel-2 starvation the user observed — the article-list `.task` fetch
/// waited behind an in-progress sync/classification write on the single writer
/// actor, so the middle pane sat on its spinner during sync. Sharing ONE
/// container (one coordinator) keeps `PersistentIdentifier`s interoperable, so
/// the render/selection path (`modelContext.model(for:)` on reader-returned
/// IDs) is unchanged.
///
/// **Why shared container, not a separate one (STACK.md § 14).** A separate
/// container on the same store URL was evaluated and REJECTED: its coordinator
/// mints `PersistentIdentifier`s that do NOT resolve via `model(for:)` in the
/// app container (empirically a hard crash — the selection path). The supported
/// SwiftData pattern is `mainContext` + additional `ModelActor` contexts on ONE
/// container; the coordinator serializes store access, so a concurrent op
/// briefly BLOCKS rather than throwing. The Core Data `NSException` seen earlier
/// was a TEST-PARALLELISM artifact (dozens of concurrent containers/coordinators
/// in the parallel test target) — NOT a production hazard; an isolated 1+1
/// production-shape stress test (`DataReaderConcurrencyTests`) is clean under
/// Thread Sanitizer.
///
/// **Read-only by contract.** `DataReader` performs zero `insert` / `save` —
/// ALL writes stay on `DataWriter` (`STACK.md § 0 / § 5` — "all writes through
/// `DataWriter`"), and its context has `autosaveEnabled = false`. It returns
/// only `Sendable` DTOs + `[PersistentIdentifier]`; no `@Model` crosses the
/// actor boundary (`STACK.md § 0 → Actor boundaries`).
///
/// **Freshness.** `DataReader`'s context sees a writer's committed `save()` on
/// its next fetch. `DataReaderConcurrencyTests` proves this empirically for the
/// registered-object path rather than trusting default staleness behaviour —
/// the load-bearing cases are `fetchUnreadCountsSnapshot` (reads
/// `primaryCategory` / `primaryFolder` off possibly-registered objects to
/// bucket counts) and `fetchEntrySections`' row projection (reads `isRead`,
/// `title`, … into `EntryRowDTO` value snapshots). The old "no volatile
/// scalar" staleness-immunity contract is deliberately RETIRED (issue #148):
/// rows are snapshots of COMMITTED state; freshness is bounded by the bump
/// pipeline (immediate write bumps, ≤ 1 s idle / ≤ 4 s dwell mid-flight
/// drains, remote read flips on the sync-edge tick); and the `pendingReadIDs`
/// overlay is retained until a refetched source confirms `isRead == true`
/// (`retainedPendingReadIDs`). See `EntryRowDTO`'s doc for the full contract.
///
/// **No dirty reads (journal-mode-independent).** The reader never observes a
/// writer's UNCOMMITTED changes: SQLite never exposes an open transaction's
/// data across connections, in ANY journal mode. This holds only because the
/// reader has zero unsaved changes of its own (`autosaveEnabled = false` + no
/// insert/save — the read-only invariant above); `ModelContext` fetches include
/// pending changes by default, so a stray write would leak uncommitted state
/// into results. `DataReaderConcurrencyTests` guards the invariant.
///
/// **Non-starvation is actor-mailbox-level.** The win is that the reader is a
/// SEPARATE ACTOR: a read is never enqueued behind the writer actor's backlog
/// (the spinner cause). It is NOT a claim of fully-parallel store access — one
/// shared coordinator serializes store operations, so a read concurrent with a
/// write may briefly wait at the coordinator (WAL keeps that brief; it never
/// throws). `DataReaderConcurrencyTests.readerNotSeriallyDependentOnWriter`
/// asserts the reader is not serially dependent on a writer op's completion via
/// event ordering (not a wall-clock bound). WAL is the on-disk store's default
/// journal mode (see `FeederApp.deleteStoreFiles` clearing `store-wal`).
actor DataReader: ModelActor {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    // Off-main custom executor (issue #135, STACK.md § 14). `DefaultSerialModelExecutor`
    // ran the reader on the MAIN thread; `BackgroundSerialModelExecutor` binds it
    // to a background serial queue so reads never block the UI. Own instance —
    // sharing the writer's would re-serialise reads behind writes (PR #160).
    self.modelExecutor = BackgroundSerialModelExecutor(
      modelContext: context, queueLabel: "com.feeder.datareader")
  }

  /// Construct a `DataReader` on a detached background task — same idiom as
  /// `DataWriter.makeDetached`, honouring `STACK.md § 0 → Actor boundaries`
  /// ("init must happen on a background thread").
  static func makeDetached(modelContainer: ModelContainer) async -> DataReader {
    await Task.detached(priority: .utility) {
      DataReader(modelContainer: modelContainer)
    }.value
  }

  // MARK: - Article list (background-fetched section snapshots)

  /// Predicate that captures the shared "is this row eligible to count
  /// towards the unread sidebar badges and appear in the unread article
  /// list" rule: classified, unread, and published on or after `cutoffDate`.
  ///
  /// `fetchUnreadCountsSnapshot` uses this verbatim; `fetchEntrySections`
  /// composes the same three clauses inline alongside its per-axis
  /// (category / folder), `showRead` override, and `pinnedFeedbinEntryID`
  /// clauses. The two fetchers must agree on the eligible row set whenever
  /// `showRead == false`, which is the only shape the sidebar counts —
  /// the PR #103 regression where the snapshot's predicate drifted out of
  /// sync with the article-list fetch (sidebar badges counted rows the
  /// list had hidden) is what this helper prevents from recurring. Moving
  /// both fetchers onto `DataReader` keeps this DRY guard intact and keeps
  /// the two reads on ONE context (a split would risk torn reads).
  ///
  /// Per `STACK.md § 13 → Change discipline (DRY)` and Apple's
  /// [Filtering and sorting persistent data](https://developer.apple.com/documentation/swiftdata/filtering-and-sorting-persistent-data)
  /// guide: a single `static` helper returning `Predicate<Entry>` is the
  /// canonical reuse shape, callable from any thread (the predicate is
  /// `Sendable`).
  static func unreadEligiblePredicate(cutoffDate: Date) -> Predicate<Entry> {
    #Predicate<Entry> {
      $0.isClassified && $0.isRead == false && $0.publishedAt >= cutoffDate
    }
  }

  /// Fetch entries for an article list selection, project them into
  /// `EntryRowDTO` snapshots, and group them by calendar day. The heavy SQLite
  /// fetch + projection + grouping + aggregate flattening all happen on this
  /// background `ModelActor`, so MainActor renders the sections without any
  /// store access (issue #148).
  /// Pass either `category` or `folder`; the other should be nil. If both are
  /// nil, returns an empty result.
  ///
  /// The classified + unread/showRead + cutoff core is built from
  /// `unreadEligiblePredicate(cutoffDate:)` plus the `showRead` / pinned-entry
  /// overrides; per-axis category or folder clauses compose on top.
  ///
  /// `window` (issue #155) bounds WHICH slice of the canonical order is
  /// fetched — deliberately no default, so every call site states its paging
  /// intent. All three modes run the same predicate core and the same sort;
  /// they differ only in the keyset clause built by `entryListDescriptor`
  /// (never `fetchOffset`, never in-Swift filtering — `STACK.md § 7`).
  /// `firstPage` auto-grows to cover the pinned row's sort position
  /// (`pinCoveringLimit`) so the selected row never falls outside the window.
  func fetchEntrySections(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinnedFeedbinEntryID: Int? = nil, window: EntryListWindow
  ) throws -> EntryListFetchResult {
    // Kill queued stale fetches before they touch the store: under rapid J/K
    // the serial reader mailbox accumulates fetches whose owning `.task` was
    // already cancelled by a structural-key change. Actor methods run in the
    // caller's task, so this observes the SwiftUI task's cancellation.
    // Checked BEFORE the signpost begin so aborted fetches do not skew
    // `read-fetch-sections` stats (issue #146).
    // Off-main invariant (issue #135): `BackgroundSerialModelExecutor` must keep
    // this read off the main thread. Fails loudly if a regression ever puts it
    // back on main.
    dispatchPrecondition(condition: .notOnQueue(.main))
    try Task.checkCancellation()
    // C3 attribution (issue #138): time the article-list read on the reader
    // actor. Zero-cost when no profiler is attached; `defer` closes on throw.
    // The end message carries the paging mode + row count (issue #155) so a
    // trace can split first-page / append / refresh cost — counts only, no
    // user-derived labels (`STACK.md § 8`).
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
    // `pinnedFeedbinEntryID` keeps the currently-selected row visible even when
    // its `isRead` flips out of the filter (typically after cross-device sync
    // marks it read elsewhere). Sentinel of 0 is safe — Feedbin assigns
    // positive entry IDs only.
    let pinned = pinnedFeedbinEntryID ?? 0
    // Resolve the window into the shared keyset inputs. `firstPage` is an
    // `after` fetch from a top sentinel cursor, so the first page and its
    // appends tile BY CONSTRUCTION — one clause family, no seam to disagree
    // on. `atOrAbove` is the whole-window refresh: unbounded above the
    // cursor, bounded by how far the user has actually grown the window.
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
      // hasMore exactness: fetch ONE row past the window and drop it below —
      // no COUNT query, no false positive at an exactly-full page.
      descriptor.fetchLimit = pageLimit + 1
    }
    // Projection contract (issue #148): hydrate ONLY the columns
    // `projectEntryRow` reads — `plainText` is deliberately EXCLUDED (it is
    // the full article body; the projection faults it per-row, off-main, only
    // when `summaryPlainText` is empty) — and prefetch the `feed`
    // relationship in the same fetch so the favicon key + fallback initial
    // resolve without a per-row relationship fault.
    descriptor.propertiesToFetch = [
      \.feedbinEntryID, \.title, \.formattedPublishedTime, \.displayDomain,
      \.summaryPlainText, \.isRead, \.publishedAt,
    ]
    descriptor.relationshipKeyPathsForPrefetching = [\.feed]
    var entries = try modelContext.fetch(descriptor)
    var effectiveLimit = pageLimit
    // Pin coverage (revived from PR #153, issue #155): a bare first page can
    // exclude the pinned (selected) row. Grow the window to the pin's sort
    // position and refetch the grown prefix ONCE — chronology stays
    // continuous; the pin is never unioned out-of-band (that would render a
    // timeline gap). Only `firstPage` grows: appends tile below an
    // already-covered window, and `atOrAbove` re-fetches a window that
    // covered the pin when it was built.
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
    // `atOrAbove` has no limit to overshoot — probe for rows below the
    // returned window with ONE `after(lastRow, limit: 1)` fetch so `hasMore`
    // stays exact across refreshes.
    if case .atOrAbove = window, let lastRow = rows.last {
      hasMore = try hasRowsBelow(
        category: category, folder: folder, showRead: showRead, cutoffDate: cutoffDate,
        pinned: pinned,
        cursor: EntryListCursor(
          publishedAt: lastRow.publishedAt, feedbinEntryID: lastRow.feedbinEntryID))
    }
    let sections = groupRowsByDay(rows)
    // Sort order of `sections` matches `rows` (both descend on publishedAt
    // then feedbinEntryID), so a single pass over `rows` produces the same
    // identifier sequence the sections carry — avoids a second walk; the
    // MainActor consumes the aggregates via `VisibleEntriesKey`.
    return EntryListFetchResult(
      sections: sections,
      allEntryIDs: rows.map(\.persistentID),
      distinctFeedIDs: Set(rows.compactMap(\.feedFeedbinID)),
      renderedUnreadFeedbinEntryIDs: Set(rows.lazy.filter { !$0.isRead }.map(\.feedbinEntryID)),
      hasMore: hasMore
    )
  }

  /// The ONE builder for every article-list descriptor (issue #155): the
  /// eligibility core (classified + per-axis + showRead/pin override +
  /// cutoff) composed with one of the two keyset clauses. Four `#Predicate`
  /// literals because `#Predicate` cannot compose sub-predicates — the clause
  /// pair is the single place the keyset ordering rule lives:
  /// - after(C):     `publishedAt < C.date OR (== AND feedbinEntryID < C.id)`
  /// - atOrAbove(C): `publishedAt > C.date OR (== AND feedbinEntryID >= C.id)`
  /// The two partition the sorted result exactly at C, so pages tile with no
  /// dup and no skip. Returns nil when neither axis is set.
  private func entryListDescriptor(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinned: Int, cursor: EntryListCursor, usesAfterClause: Bool
  ) -> FetchDescriptor<Entry>? {
    // Secondary sort on feedbinEntryID keeps order deterministic when two entries
    // share the same publishedAt timestamp. Without it, two equal-timestamp rows
    // can swap places between fetches, which defeats the Equatable diff skip in
    // EntryListView.reload() and can cause the list to reshuffle briefly. The
    // keyset clauses above break ties on the SAME key, so page seams stay
    // deterministic through an equal-timestamp run.
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

  /// Exact `hasMore` probe for the `atOrAbove` refresh: ONE `after(lastRow,
  /// limit: 1)` fetch through the same descriptor builder — non-empty means
  /// the store holds at least one eligible row below the returned window.
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

  /// Smallest window that keeps the pinned (selected) row inside the first
  /// page — the pin-coverage rule revived from PR #153 (issue #155). Returns
  /// nil when the pinned row is missing or ineligible for this context
  /// (wrong category/folder, unclassified, or beyond the cutoff) — then
  /// there is nothing to cover.
  ///
  /// The by-key lookup reads a handful of unlisted columns off ONE row,
  /// off-main — the sanctioned exception scale, like `plainText` in the
  /// projection. The pin's 1-based position in the sorted result IS the
  /// count of rows at-or-above its key, so the count reuses the `atOrAbove`
  /// clause family via `entryListDescriptor` — position counting and window
  /// fetching can never disagree on the ordering rule.
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

  /// Project one fetched `Entry` into its Sendable row snapshot, ON this
  /// background actor.
  ///
  /// REVIEW RULE: this projection may touch ONLY the columns listed in
  /// `fetchEntrySections`' `propertiesToFetch` plus the prefetched `feed`
  /// relationship — accessing any unlisted property fires a per-row SQLite
  /// fault, the cost class issue #148 removes. The ONE sanctioned exception:
  /// `plainText` (the full article body) is deliberately excluded from
  /// `propertiesToFetch` and faulted per-row HERE, off-main, only when
  /// `summaryPlainText` is empty.
  private func projectEntryRow(_ entry: Entry) -> EntryRowDTO {
    let summary = entry.summaryPlainText
    let feed = entry.feed
    return EntryRowDTO(
      persistentID: entry.persistentModelID,
      feedbinEntryID: entry.feedbinEntryID,
      title: entry.title,
      formattedPublishedTime: entry.formattedPublishedTime,
      displayDomain: entry.displayDomain,
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

  /// Fetch favicon blobs for the given feeds in ONE background query —
  /// `propertiesToFetch` limits hydration to the key + blob columns. Returns
  /// only feeds that HAVE data; a missing key is `FaviconStore`'s
  /// negative-cache signal (initials fallback, never refetched).
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

  /// Precompute per-category / per-folder unread counts plus the underlying
  /// ID sets in a single streaming fetch on the `DataReader` actor. The
  /// resulting `UnreadCountsSnapshot` is the sole input the sidebar needs to
  /// render its badges — the MainActor `@Query unreadEntries` that previously
  /// drove this aggregation is gone.
  ///
  /// Predicate mirrors `fetchEntrySections` so sidebar badges and middle-pane
  /// lists count the same rows; `cutoffDate` is `syncEngine.queryCutoffDate`
  /// at call time. Without this clause, entries between `articleKeepDays`
  /// (default 7d) and `maxRetentionAge` (30d) that are still unread+classified
  /// would be counted in the sidebar but hidden from the article list.
  ///
  /// Streams via `ModelContext.enumerate(_:batchSize:)` so SwiftData hydrates
  /// rows in 500-entry chunks rather than materializing the full unread
  /// universe at once
  /// (`https://developer.apple.com/documentation/swiftdata/modelcontext/enumerate(_:batchsize:allowescapingmutations:block:)`).
  /// `propertiesToFetch` limits column hydration to the three fields the
  /// aggregation reads, avoiding fault-handler walks over `articleBlocksData`
  /// and friends
  /// (`https://developer.apple.com/documentation/swiftdata/fetchdescriptor/propertiestofetch`).
  func fetchUnreadCountsSnapshot(cutoffDate: Date) throws -> UnreadCountsSnapshot {
    // Off-main invariant (issue #135): this aggregation materialises the unread
    // universe; `BackgroundSerialModelExecutor` must keep it off the main thread.
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
