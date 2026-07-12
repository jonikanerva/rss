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
/// the load-bearing case is `fetchUnreadCountsSnapshot`, which reads
/// `primaryCategory` / `primaryFolder` off possibly-registered objects to
/// bucket counts. `fetchEntrySections` is staleness-IMMUNE by construction: its
/// DTOs carry only `PersistentIdentifier`s plus write-time-immutable section
/// labels — no volatile `Entry` scalar is read into the result, so membership
/// and order stay SQL-committed-truthful.
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
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
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

  /// Fetch entries for an article list selection and group them by calendar day.
  /// Returns an `EntryListFetchResult` carrying lightweight `EntryListSection`
  /// DTOs (persistent IDs + precomputed section labels) plus the pre-flattened
  /// entry-ID list. The heavy SQLite fetch + Entry materialization + grouping
  /// + flattening all happen on this background `ModelActor`, so MainActor
  /// stays free to render the loading state immediately and never pays for a
  /// `flatMap(\.entryIDs)` across the entire row set.
  /// Pass either `category` or `folder`; the other should be nil. If both are
  /// nil, returns an empty result.
  ///
  /// The classified + unread/showRead + cutoff core is built from
  /// `unreadEligiblePredicate(cutoffDate:)` plus the `showRead` / pinned-entry
  /// overrides; per-axis category or folder clauses compose on top.
  func fetchEntrySections(
    category: String?, folder: String?, showRead: Bool, cutoffDate: Date,
    pinnedFeedbinEntryID: Int? = nil
  ) throws -> EntryListFetchResult {
    // Kill queued stale fetches before they touch the store: under rapid J/K
    // the serial reader mailbox accumulates fetches whose owning `.task` was
    // already cancelled by a structural-key change. Actor methods run in the
    // caller's task, so this observes the SwiftUI task's cancellation.
    // Checked BEFORE the signpost begin so aborted fetches do not skew
    // `read-fetch-sections` stats (issue #146).
    try Task.checkCancellation()
    // C3 attribution (issue #138): time the article-list read on the reader
    // actor. Zero-cost when no profiler is attached; `defer` closes on throw.
    let signpost = perfSignposter.beginInterval(PerformanceSignpostName.readFetchSections)
    defer { perfSignposter.endInterval(PerformanceSignpostName.readFetchSections, signpost) }
    let descriptor: FetchDescriptor<Entry>
    // Secondary sort on feedbinEntryID keeps order deterministic when two entries
    // share the same publishedAt timestamp. Without it, two equal-timestamp rows
    // can swap places between fetches, which defeats the Equatable diff skip in
    // EntryListView.reload() and can cause the list to reshuffle briefly.
    let entrySort: [SortDescriptor<Entry>] = [
      SortDescriptor(\Entry.publishedAt, order: .reverse),
      SortDescriptor(\Entry.feedbinEntryID, order: .reverse),
    ]
    // `pinnedFeedbinEntryID` keeps the currently-selected row visible even when
    // its `isRead` flips out of the filter (typically after cross-device sync
    // marks it read elsewhere). Sentinel of 0 is safe — Feedbin assigns
    // positive entry IDs only.
    let pinned = pinnedFeedbinEntryID ?? 0
    if let category {
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryCategory == category
            && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
            && $0.publishedAt >= cutoffDate
        },
        sortBy: entrySort
      )
    } else if let folder {
      descriptor = FetchDescriptor<Entry>(
        predicate: #Predicate<Entry> {
          $0.isClassified && $0.primaryFolder == folder
            && ($0.isRead == showRead || $0.feedbinEntryID == pinned)
            && $0.publishedAt >= cutoffDate
        },
        sortBy: entrySort
      )
    } else {
      return .empty
    }
    let entries = try modelContext.fetch(descriptor)
    // The fetch is the dominant cost; re-check before paying for grouping
    // when the consuming task is already gone.
    try Task.checkCancellation()
    let sections = groupEntriesByDay(entries)
    // Sort order of `sections` matches `entries` (both descend on publishedAt
    // then feedbinEntryID), so a single pass over `entries` produces the same
    // identifier sequence `sections.flatMap(\.entryIDs)` would — avoids a
    // second walk and matches what `EntryListView.reload()` consumes via
    // `VisibleEntryIDsKey`.
    let allEntryIDs = entries.map(\.persistentModelID)
    return EntryListFetchResult(sections: sections, allEntryIDs: allEntryIDs)
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
