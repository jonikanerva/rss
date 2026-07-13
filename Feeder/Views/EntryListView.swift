import SwiftData
import SwiftUI
import os
import os.signpost

/// Flags an article-list fetch failure (a store error thrown by the reader).
/// One error line per failure; the category / folder label is user-derived
/// taxonomy, so it is interpolated `.private` (`STACK.md § 8`).
private let logger = Logger(subsystem: "com.feeder.app", category: "EntryListView")

// MARK: - Visible Entries Preference Key

/// Payload for `VisibleEntriesKey`: the currently rendered entry ids (Tab
/// selects the first as the new `selectedEntryID`) plus the rendered-unread
/// feedbin ids — the rendered side of the two-sided `pendingReadIDs`
/// retention prune (`retainedPendingReadIDs`, issue #148). Both aggregates
/// are computed off-main by `DataReader.fetchEntrySections`; the view just
/// bubbles them.
nonisolated struct VisibleEntriesPayload: Sendable, Equatable {
  let ids: [PersistentIdentifier]
  let unreadFeedbinEntryIDs: Set<Int>

  static let empty = VisibleEntriesPayload(ids: [], unreadFeedbinEntryIDs: [])
}

/// Bubbles the rendered-entries payload from EntryListView up to ContentView.
struct VisibleEntriesKey: PreferenceKey {
  static let defaultValue: VisibleEntriesPayload = .empty
  static func reduce(value: inout VisibleEntriesPayload, nextValue: () -> VisibleEntriesPayload) {
    value = nextValue()
  }
}

// MARK: - Entry List View (background-fetched section snapshots, no MainActor @Query)

/// Renders the article list for a given sidebar selection.
///
/// **Why not `@Query`**: SwiftData's `@Query` runs synchronously on MainActor
/// during view init/body. For large categories (e.g. "uncategorized" with
/// thousands of entries), the SQLite fetch + Entry materialization + day-grouping
/// blocks the main thread for seconds.
///
/// Instead, the heavy fetch + projection + grouping runs on `DataReader` (a
/// `@ModelActor`, so on a background thread). The view holds
/// `[EntryListSection]` state whose rows are complete `EntryRowDTO` value
/// snapshots (issue #148) — each row renders from its DTO plus the
/// `FaviconStore` image; there is NO per-row `modelContext.model(for:)` and
/// NO `entry.feed` relationship fault on MainActor. Selection carries the
/// row's `PersistentIdentifier`; `ContentView` resolves the ONE full `Entry`
/// per selection at the detail boundary.
///
/// **The `List` stays mounted across reloads (issue #146).** The old shape
/// swapped `ProgressView` ↔ `List` on a `hasLoaded` boolean, so every
/// structural reload destroyed and rebuilt the entire row tree — an
/// O(all-rows) view-list construction + layout that was the measured
/// `structural-reload` tail (p90 915 ms, max 1.9 s). Now `fetchPhase`
/// (`FetchPhase`, pure domain) feeds `entryListDisplayState(...)`, and the
/// pending window renders the SAME mounted `List` with zero rows — a calm
/// blank pane — so a resolved fetch applies as an incremental diff.
/// "No Articles" is asserted only by a RESOLVED empty fetch, never during
/// `pending` (the relocated #137 protection) and never while rows exist.
///
/// **Live updates**: lost compared to `@Query` auto-refresh. Replaced by
/// explicit refresh-version triggers driven from `ContentView` — `.onChange`
/// handlers on `syncEngine.isSyncing` / `classificationEngine.isClassifying`
/// false-transitions, the mid-flight deferred-bump drains (which also
/// live-populate a viewed category while classification lands rows), plus an
/// explicit bump after `flushPendingReads` and `markAllAsRead` writes.
///
/// **Keyset window (issue #155).** The view holds a bounded window of the
/// canonical order, defined by its bottom edge — the derived cursor of the
/// last loaded row. Three channels, three windows: structural →
/// `firstPage(pageSize)`; refresh → `atOrAbove(cursor)` (whole-window
/// replace in one snapshot, with a first-page fallback when it resolves
/// empty); append → `after(cursor, pageSize)` on its own task. Appends are
/// invisible chrome-wise: no "Load more" control, no spinner, no animation —
/// rows simply exist when the user gets there. Chronology is untouched —
/// paging tiles the SAME sorted result; nothing is reordered or hidden
/// (`VISION.md → Core Principles`).
struct EntryListView: View {
  let category: String?
  let folder: String?
  let filter: ArticleFilter
  let cutoffDate: Date
  let reader: DataReader
  let refreshVersion: Int
  /// When non-nil, the row with this Feedbin entry ID is retained in the fetch
  /// result regardless of `isRead == showRead` — keeps a selected article
  /// visible after a cross-device sync flips its read state. The pin rides
  /// along with the next refresh trigger; selection changes alone do not
  /// re-fetch (avoids per-click background work).
  let pinnedFeedbinEntryID: Int?
  @Binding
  var selectedEntryID: PersistentIdentifier?
  let onMarkAllRead: () -> Void

  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(FaviconStore.self)
  private var faviconStore
  @Environment(AppFontSettings.self)
  private var fontSettings
  @Environment(\.openSettings)
  private var openSettings
  @State
  private var sections: [EntryListSection] = []
  /// Rendered-entries payload cached for the `VisibleEntriesKey` preference.
  /// Computed once per fetch (off-main, by the reader) instead of walking
  /// `sections` on every body re-eval — meaningful for large categories
  /// ("uncategorized" with thousands of rows).
  @State
  private var visibleEntries: VisibleEntriesPayload = .empty
  /// Fetch lifecycle for the current structural context — the tagged union
  /// that replaced the `hasLoaded` boolean (issue #146). Drives
  /// `entryListDisplayState(...)` together with `sections`.
  @State
  private var fetchPhase: FetchPhase = .pending
  /// Whether the store holds eligible rows below the loaded window
  /// (issue #155). Exact — see `EntryListFetchResult.hasMore`. Gates the
  /// append triggers; reset by the structural prefix.
  @State
  private var hasMore = false
  /// Append channel version — bumping it re-keys the append `.task`, which
  /// fetches ONE `after(cursor, limit:)` page. The id also embeds
  /// `structuralKey`, so a category switch auto-cancels an in-flight append
  /// (`STACK.md § 7` — structured cancellation only).
  @State
  private var appendVersion = 0
  /// One append in flight at a time: the trigger paths (row appearance /
  /// selection reaching the last row) may fire repeatedly while the page
  /// fetch runs; this keeps them from stacking version bumps.
  @State
  private var isAppending = false
  /// The row whose appearance requests the next append — `appendTriggerMargin`
  /// rows before the window end, precomputed once per apply from
  /// `allEntryIDs` (never derived in `body`). nil when nothing more to load.
  @State
  private var appendTriggerID: PersistentIdentifier?
  /// Carries the anchor row + alignment from `reload()`'s pre-diff inspection
  /// to the post-diff `proxy.scrollTo` call. The pin is conditional on what
  /// `reload()` sees in the new result and is set to `nil` when no restore is
  /// warranted (selection cleared with no fallback, structural reload, or
  /// empty case). Kept as state because the producer and consumer sit in the
  /// same async function but bracket the `sections = result` assignment.
  @State
  private var pendingAnchorRestore: AnchorRestore?

  /// Anchor + alignment pair for `ScrollViewReader.scrollTo`. `.center` keeps
  /// a still-selected row visible after a Read/Unread filter flip or a
  /// classification batch reshuffle; `.top` keeps the previously-first row
  /// pinned at the top when a sync page lands new entries above it (so the
  /// viewport stays visually stable rather than scrolling along with the
  /// insert).
  private struct AnchorRestore: Equatable {
    let id: PersistentIdentifier
    let anchor: UnitPoint
  }

  /// Debounce window for a structural (category / folder / filter) navigation
  /// change (issue #146). Coalesces a rapid J/K burst into ONE reload: each
  /// intermediate keypress cancels the prior `.task(id: structuralKey)` while it
  /// is still in this cheap sleep, before it can blank the pane or queue a fetch
  /// on the serial `DataReader` actor. Tunable — imperceptible for a single
  /// deliberate nav, long enough to swallow a burst.
  private static let navDebounce: Duration = .milliseconds(150)

  /// Keyset page size (issue #155): the first page and every appended page
  /// load this many rows. Internal constant, deliberately NOT a preference —
  /// one opinionated way (`VISION.md → Non-Goals`).
  private static let pageSize = 100

  /// How many rows before the window end the append-trigger row sits, so the
  /// next page usually lands before the user reaches the bottom — by scroll
  /// OR by J/K (the trigger row's `onAppear` fires for both). Internal
  /// constant, never a preference.
  private static let appendTriggerMargin = 20

  var body: some View {
    // `ScrollViewReader` is transparent — it adds no chrome — and lives
    // OUTSIDE the conditional `Group`, so the `.task` modifiers attach to the
    // ScrollViewReader's body and stay mounted for the lifetime of the view,
    // not for the lifetime of whichever branch is currently selected. (An
    // earlier shape nested it inside one branch and the tasks never ran on
    // first render.)
    //
    // `proxy.scrollTo(_:anchor:)` resolves `.id(...)` tags anywhere in the
    // ScrollViewReader's subtree, so the List rows below stay reachable.
    ScrollViewReader { proxy in
      Group {
        // Two-branch shape (issue #146): the empty family renders ONLY when
        // a resolved/failed fetch left zero sections; every other state —
        // rows present, or a pending fetch — renders the SAME mounted
        // `List`. `.blank` deliberately shares the `List` branch (zero rows
        // = a calm blank pane): a spinner branch or a separate blank branch
        // would remount the `List` on every structural reload, which was the
        // O(all-rows) rebuild this issue removes.
        switch displayState {
        case .authFailed:
          ContentUnavailableView {
            Label(
              "Signed out of Feedbin",
              systemImage: "person.crop.circle.badge.exclamationmark")
          } description: {
            Text("Sign in again to resume syncing your feeds.")
          } actions: {
            Button("Sign In Again") { openSettings() }
              .buttonStyle(.borderedProminent)
              .accessibilityIdentifier("timeline.authError.signIn")
          }
        case .offline:
          ContentUnavailableView(
            "Offline",
            systemImage: "wifi.slash",
            description: Text("Connect to the internet to sync new articles.")
          )
        case .error:
          ContentUnavailableView {
            Label("Couldn't Load Articles", systemImage: "exclamationmark.triangle")
          } description: {
            Text("Select the category again to retry.")
          }
          .accessibilityIdentifier("timeline.error")
        case .noArticles:
          ContentUnavailableView {
            Label("No Articles", systemImage: "newspaper")
          } description: {
            Text(
              filter == .unread
                ? "No unread articles in this category."
                : "No read articles in this category."
            )
          }
        case .blank, .list:
          List(selection: $selectedEntryID) {
            ForEach(sections) { section in
              Section {
                // Rows render straight from their DTO snapshots — zero store
                // access on MainActor (issue #148). The favicon is a sync
                // dictionary lookup; decode happened once in `FaviconStore`.
                ForEach(section.rows) { row in
                  EntryRowView(
                    row: row,
                    faviconImage: faviconStore.image(for: row.feedFeedbinID)
                  )
                  .tag(row.persistentID)
                  .id(row.persistentID)
                  .listRowSeparator(.hidden)
                  // Keyboard-parity append trigger (issue #155): the trigger
                  // row's appearance fires for scroll AND for J/K row
                  // navigation — `List` materialises the row either way. A
                  // plain id comparison against the precomputed trigger id;
                  // no per-row math in `body` (`STACK.md § 0 / § 4`).
                  .onAppear {
                    if row.persistentID == appendTriggerID { requestAppend() }
                  }
                }
              } header: {
                Text(section.label)
                  .font(fontSettings.sectionLabel)
                  .foregroundStyle(.tertiary)
                  .textCase(nil)
              }
            }
          }
          .listStyle(.inset(alternatesRowBackgrounds: false))
          .modifier(BareKeyHandler())
          .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
          .preference(key: VisibleEntriesKey.self, value: visibleEntries)
          .accessibilityIdentifier("timeline.list")
        }
      }
      // Two tasks so refresh-only ticks (classification / sync completion)
      // do not re-run the structural path and drop the rows to the blank
      // pane. `structuralKey` captures inputs whose change means "user is
      // looking at a different list" (category / folder / filter / cutoff);
      // only those clear the previous rows. `refreshVersion` fires in place
      // and `reload()` skips the assign when sections are equal, so
      // SwiftUI's diff keeps the scroll stable.
      //
      // The refresh task's id intentionally includes `structuralKey`:
      // a bare `refreshVersion` id would not be cancelled when the user
      // switches category mid-refresh, and the in-flight fetch — which
      // captured `self` with the old category — could race the
      // structural task and overwrite `sections` with stale rows from
      // the previous list. Including `structuralKey` cancels the stale
      // refresh when context changes, and the `guard fetchPhase != .pending`
      // check keeps the restarted refresh a no-op while the structural task
      // owns the reload.
      .task(id: structuralKey) {
        // Debounce a rapid J/K category-nav burst (issue #146). Placed at the
        // VERY TOP — before the signpost begin, the `.pending` blank prefix, and
        // the reader fetch — so an intermediate keypress (which `.task(id:)`
        // cancels the instant `structuralKey` changes) exits HERE during the
        // cheap sleep: no stacked `structural-reload` signpost, no blanked pane,
        // and no fetch queued on the serial `DataReader` actor. Only the SETTLED
        // selection survives → one blank + one fetch, so the sidebar highlight
        // paints per keypress and the previous rows stay until the user settles.
        // Cancellation-safe by construction: `.task(id:)`'s own structured
        // cancellation, no manual Task / Timer (`STACK.md § 7 / § 9`). The
        // `try?` swallows the sleep's `CancellationError`, so the explicit
        // `Task.isCancelled` re-check is what turns a cancelled burst step into
        // a no-op. The SEPARATE `.task(id: refreshTaskKey)` refresh path is
        // deliberately NOT debounced.
        try? await Task.sleep(for: Self.navDebounce)
        guard !Task.isCancelled else { return }
        // C3 perception/occupancy (issue #138): bracket the panel-2 blank
        // window (structural key change → sections replaced). `defer` closes
        // it even if the task is cancelled mid-reload by a structural-key
        // change.
        let signpost = perfSignposter.beginInterval(PerformanceSignpostName.structuralReload)
        // Tag the END with the resolved row count + category so a capture can
        // plot reload time against N from any real store (issue #146 confound-
        // killer) — read at `defer` time, after `reload` has assigned
        // `visibleEntries`. Count + category label only; no PII (STACK.md §8).
        defer {
          perfSignposter.endInterval(
            PerformanceSignpostName.structuralReload, signpost,
            "rows=\(visibleEntries.ids.count, privacy: .public) cat=\(category ?? folder ?? "unified", privacy: .private)"
          )
        }
        // Synchronous prefix: enter the pending phase and drop the previous
        // context's rows before the first await, so the pane never shows the
        // old category's rows while the new fetch runs. Paging state resets
        // with the window (issue #155): a new structural context starts from
        // a fresh first page.
        fetchPhase = .pending
        sections = []
        visibleEntries = .empty
        hasMore = false
        appendTriggerID = nil
        appendVersion = 0
        isAppending = false
        if await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy) {
          fetchPhase = .resolved
          return
        }
        guard !Task.isCancelled else { return }
        // No retry: the shared coordinator BLOCKS rather than throws under
        // contention (`STACK.md § 14`, `DataReader` header), so a fetch throw
        // is almost certainly persistent — a delayed retry would only
        // postpone showing the truth. Self-healing is free: any refresh bump
        // re-fetches (a success sets `.resolved`), and re-selecting the
        // category restarts this task.
        fetchPhase = .failed
      }
      .task(id: refreshTaskKey) {
        guard fetchPhase != .pending else { return }
        // A successful refresh sets `.resolved`, so any later bump heals an
        // earlier `.failed` pane. A failed or cancelled refresh keeps the
        // previous phase: existing rows stay (resolved) or the error pane
        // stays (failed) — never a false empty.
        if await refresh(proxy: proxy) {
          fetchPhase = .resolved
        }
      }
      // Append channel (issue #155): its own task so an append neither
      // debounces like the structural path nor replaces the window like the
      // refresh path. The id embeds `structuralKey` — a category switch
      // cancels an in-flight append together with everything else.
      .task(id: appendTaskKey) {
        guard isAppending else { return }
        await appendNextPage()
        isAppending = false
      }
      // Keyboard-parity trigger (issue #155, ux condition A): End / Page-Down
      // can land selection on the LAST loaded row without the trigger row's
      // `onAppear` ever firing (SwiftUI may skip materialising the rows in
      // between). Selection reaching the window's bottom edge requests the
      // next page directly.
      .onChange(of: selectedEntryID) { _, newValue in
        if let newValue, newValue == visibleEntries.ids.last {
          requestAppend()
        }
      }
    }
  }

  /// Single derivation point for what the pane shows — the pure precedence
  /// rule in `Helpers/EntryListDisplayState.swift` (unit-tested truth table).
  private var displayState: EntryListDisplayState {
    entryListDisplayState(
      phase: fetchPhase,
      hasSections: !sections.isEmpty,
      isAuthFailed: isAuthFailed,
      isOffline: syncEngine.lastError?.isNetworkError == true
    )
  }

  private var isAuthFailed: Bool {
    if case .authFailed = syncEngine.lastError { return true }
    return false
  }

  /// One reader fetch for the current context and the given window. Returns
  /// nil on failure or cancellation — callers distinguish the two via
  /// `Task.isCancelled` before treating nil as a store failure.
  private func fetchResult(window: EntryListWindow) async -> EntryListFetchResult? {
    do {
      return try await reader.fetchEntrySections(
        category: category, folder: folder, showRead: filter == .read,
        cutoffDate: cutoffDate, pinnedFeedbinEntryID: pinnedFeedbinEntryID,
        window: window
      )
    } catch is CancellationError {
      // Silent exit — neither success nor failure. The reader's
      // `Task.checkCancellation` guard surfaces here when a structural-key
      // change cancels a queued stale fetch.
      return nil
    } catch {
      // Store error — logged once per failure, here so all callers share
      // it. The structural task shows the error pane; a failed refresh keeps
      // the previous phase (existing rows or the error pane).
      logger.error(
        "Article-list fetch failed for \(category ?? folder ?? "none", privacy: .private)"
      )
      return nil
    }
  }

  /// Fetch and apply the sections for the current context. Returns `true`
  /// when the fetch resolved and its result was applied (or was identical, so
  /// no apply was needed); `false` on failure or cancellation.
  private func reload(window: EntryListWindow, proxy: ScrollViewProxy) async -> Bool {
    guard let result = await fetchResult(window: window) else { return false }
    guard !Task.isCancelled else { return false }
    return await apply(result, proxy: proxy)
  }

  /// Whole-window refresh (issue #155): refetch everything at or above the
  /// loaded window's bottom edge in ONE snapshot — new rows land above,
  /// read-state flips land in place, and the appended tail is preserved.
  /// (Prefix-refetch and reset-to-first-page were rejected: both let the
  /// loaded window slip out from under the reader mid-session.)
  ///
  /// Symmetric in-flight guard (issue #155): the snapshot applies only if the
  /// window's bottom edge still equals the cursor the fetch started from — an
  /// append landing mid-refresh would otherwise be wiped by the stale (older,
  /// shorter) whole-window snapshot while the user is looking at the
  /// appended tail. On mismatch the stale result is discarded and the
  /// refresh re-fires against the current cursor.
  private func refresh(proxy: ScrollViewProxy) async -> Bool {
    while !Task.isCancelled {
      guard let fetchStartCursor = entryListCursor(of: sections) else {
        // Nothing loaded (e.g. the previous fetch failed) — a refresh from
        // an empty window is just a first page.
        return await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy)
      }
      let window = EntryListWindow.atOrAbove(fetchStartCursor)
      guard let result = await fetchResult(window: window) else { return false }
      guard !Task.isCancelled else { return false }
      guard entryListCursor(of: sections) == fetchStartCursor else { continue }
      // Refresh-empty fallback (issue #155): every loaded row left the
      // filter (e.g. mark-all-read landed) — run ONE first-page fetch so
      // rows below the old window surface instead of a false "No Articles".
      if refreshRequiresFirstPageFallback(window: window, result: result) {
        return await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy)
      }
      return await apply(result, proxy: proxy)
    }
    return false
  }

  /// Apply a fetched first-page / refresh snapshot: diff-skip, anchor
  /// restore, state assignment, favicon warm, paging-state update. Appends
  /// go through `appendNextPage` instead — they extend the tail and never
  /// run anchor-restore.
  private func apply(_ result: EntryListFetchResult, proxy: ScrollViewProxy) async -> Bool {
    // Sub-cost split (issue #146, diagnostic): time the O(N) Equatable
    // structural-equality walk of the full row set on MainActor.
    let diffSignpost = perfSignposter.beginInterval(PerformanceSignpostName.reloadDiff)
    let sectionsUnchanged = result.sections == sections
    perfSignposter.endInterval(PerformanceSignpostName.reloadDiff, diffSignpost)
    guard !sectionsUnchanged else {
      // Rows identical, but the universe BELOW the window may have changed
      // (issue #155) — keep the append gate exact. Guarded assignment so an
      // unchanged refresh does not dirty the view.
      if hasMore != result.hasMore {
        hasMore = result.hasMore
        updateAppendTrigger(allIDs: result.allEntryIDs, hasMore: result.hasMore)
      }
      return true
    }
    // Decide whether the upcoming in-place diff warrants a scroll-anchor
    // restore. Two reasons to pin: (1) the selected row still appears in the
    // new result — keep it centred so a row-height shift (read/unread
    // weight flip) doesn't push it off-screen; (2) selection cleared and
    // the previously-first row still appears — keep the top stable when a
    // sync page lands new entries above it (option (a) per the design's
    // sync-arriving-entries autonomy decision). Structural reloads
    // (`fetchPhase == .pending` going into `reload`; the structural prefix
    // also cleared `visibleEntries`) skip the fallback so we do not pin
    // an anchor from the previous list's contents.
    //
    // `result.allEntryIDs` is precomputed off-MainActor by
    // `DataReader.fetchEntrySections` so the membership-check `Set` build is
    // the only per-reload allocation on MainActor — the flatMap walk that
    // used to live here moved to the reader.
    // Sub-cost split (issue #146, diagnostic): time the O(N) Set build.
    let setSignpost = perfSignposter.beginInterval(PerformanceSignpostName.reloadSetBuild)
    let newIDs = Set(result.allEntryIDs)
    perfSignposter.endInterval(PerformanceSignpostName.reloadSetBuild, setSignpost)
    let restore: AnchorRestore?
    if let selectedID = selectedEntryID, newIDs.contains(selectedID) {
      restore = AnchorRestore(id: selectedID, anchor: .center)
    } else if selectedEntryID == nil, fetchPhase == .resolved,
      let firstID = visibleEntries.ids.first,
      newIDs.contains(firstID)
    {
      restore = AnchorRestore(id: firstID, anchor: .top)
    } else {
      restore = nil
    }
    pendingAnchorRestore = restore
    // Sub-cost split (issue #146, diagnostic): time the @State assignments that
    // mark the view dirty (the ensuing List render + layout is the
    // structural-reload residual once the named sub-intervals are subtracted).
    let assignSignpost = perfSignposter.beginInterval(PerformanceSignpostName.reloadStateAssign)
    sections = result.sections
    visibleEntries = VisibleEntriesPayload(
      ids: result.allEntryIDs,
      unreadFeedbinEntryIDs: result.renderedUnreadFeedbinEntryIDs
    )
    hasMore = result.hasMore
    updateAppendTrigger(allIDs: result.allEntryIDs, hasMore: result.hasMore)
    perfSignposter.endInterval(PerformanceSignpostName.reloadStateAssign, assignSignpost)
    // Yield one tick so SwiftUI applies the diff before we ask the proxy
    // to scroll — without the yield `scrollTo` runs against the still-old
    // layout and the anchor row is not yet on screen to scroll to. Instant
    // scroll (no `withAnimation`) so the restore respects Reduce Motion.
    if let restore = pendingAnchorRestore {
      pendingAnchorRestore = nil
      await Task.yield()
      proxy.scrollTo(restore.id, anchor: restore.anchor)
    }
    // Warm the favicon cache AFTER the rows are applied, in the same SwiftUI
    // task — a structural-key change cancels the warm together with the
    // reload, and a cancelled warm just leaves the initials fallback until
    // the next reload. Best-effort: a warm failure never fails the reload.
    await faviconStore.ensureLoaded(feedIDs: result.distinctFeedIDs) { ids in
      try await reader.fetchFaviconData(feedbinFeedIDs: ids)
    }
    return true
  }

  /// Request the next append page (issue #155). Gated on `hasMore` (exact,
  /// reader-computed) and on one-append-at-a-time; the bump re-keys the
  /// append `.task`, which owns the fetch.
  private func requestAppend() {
    guard hasMore, !isAppending else { return }
    isAppending = true
    appendVersion &+= 1
  }

  /// Fetch ONE `after(cursor, limit:)` page below the window's bottom edge
  /// and extend the window with it. Pure tail insertion: row identity is
  /// untouched and the same-day section extends under its existing id
  /// (`EntryListFetchResult.appending`), so the `List` diff never moves a
  /// rendered row — no anchor restore, no scroll, no animation (appended
  /// rows appear without motion; Reduced Motion needs no special-casing).
  private func appendNextPage() async {
    guard let fetchStartCursor = entryListCursor(of: sections) else { return }
    guard let page = await fetchResult(window: .after(fetchStartCursor, limit: Self.pageSize))
    else { return }
    guard !Task.isCancelled else { return }
    // Symmetric in-flight guard (issue #155): apply only if the window's
    // bottom edge is still the cursor this page was fetched from — a
    // whole-window refresh or structural reload landing mid-append would
    // otherwise get a stale tail glued onto its fresh snapshot. Discarding
    // is safe: the trigger row is still near the bottom, so the next
    // appearance re-requests against the new cursor.
    guard entryListCursor(of: sections) == fetchStartCursor else { return }
    let current = EntryListFetchResult(
      sections: sections,
      allEntryIDs: visibleEntries.ids,
      distinctFeedIDs: [],
      renderedUnreadFeedbinEntryIDs: visibleEntries.unreadFeedbinEntryIDs,
      hasMore: hasMore
    )
    let merged = current.appending(page)
    sections = merged.sections
    visibleEntries = VisibleEntriesPayload(
      ids: merged.allEntryIDs,
      unreadFeedbinEntryIDs: merged.renderedUnreadFeedbinEntryIDs
    )
    hasMore = merged.hasMore
    updateAppendTrigger(allIDs: merged.allEntryIDs, hasMore: merged.hasMore)
    // Warm favicons for the appended page's feeds — deep pages would
    // otherwise render permanent initials fallbacks (the reload path warms
    // only the pages it fetched itself).
    await faviconStore.ensureLoaded(feedIDs: page.distinctFeedIDs) { ids in
      try await reader.fetchFaviconData(feedbinFeedIDs: ids)
    }
  }

  /// Precompute the append-trigger row id once per apply — `margin` rows
  /// before the window end (`appendTriggerIndex`, pure) — so the per-row
  /// `onAppear` check in `body` is a plain id comparison.
  private func updateAppendTrigger(allIDs: [PersistentIdentifier], hasMore: Bool) {
    guard hasMore,
      let index = appendTriggerIndex(
        fetchedCount: allIDs.count, margin: Self.appendTriggerMargin)
    else {
      appendTriggerID = nil
      return
    }
    appendTriggerID = allIDs[index]
  }

  /// Composed key for the refresh task so a structural change (category /
  /// folder / filter / cutoff) cancels any in-flight refresh bound to the
  /// previous context. Without the structural suffix, a refresh captured
  /// against the old `self` could finish after the structural reload and
  /// overwrite `sections` with stale rows.
  private var refreshTaskKey: String {
    "\(structuralKey)|\(refreshVersion)"
  }

  /// Composed key for the append task (issue #155) — same structural-suffix
  /// rationale as `refreshTaskKey`: a category switch cancels an in-flight
  /// append page fetch bound to the previous context.
  private var appendTaskKey: String {
    "\(structuralKey)|append|\(appendVersion)"
  }

  /// Key for "this is a different article list" — user-visible context change.
  /// Excludes `refreshVersion`, which rides on a separate task so in-place
  /// refreshes do not tear down the `List` and drop the scroll position.
  private var structuralKey: String {
    "\(category ?? "")|\(folder ?? "")|\(filter.rawValue)|\(cutoffDate.timeIntervalSince1970)"
  }
}

// MARK: - Previews

#Preview("Empty - Offline") {
  EntryListOfflinePreview()
}

#Preview("Empty - Auth Failed") {
  EntryListAuthFailedPreview()
}

#Preview("Empty While Classifying — No Articles") {
  EntryListEmptyWhileClassifyingPreview()
}

#Preview("Empty - No Articles (at rest)") {
  EntryListEmptyAtRestPreview()
}

/// Renders `EntryListView` in the offline-empty state: container is seeded
/// but contains no entries, and `SyncEngine.lastError` is set to `.network`
/// so the view picks the `ContentUnavailableView("Offline", …)` branch.
@MainActor
private struct EntryListOfflinePreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine: SyncEngine = {
    let engine = SyncEngine()
    engine.applyPreviewState(
      lastError: .network("The Internet connection appears to be offline."))
    return engine
  }()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntryID: $selectedEntryID,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(AppFontSettings())
    .environment(FaviconStore())
    .modelContainer(container)
    .task {
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the auth-failed empty state: container is seeded
/// but contains no entries, and `SyncEngine.lastError` is set to `.authFailed`
/// so the view picks the "Signed out of Feedbin" branch.
@MainActor
private struct EntryListAuthFailedPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine: SyncEngine = {
    let engine = SyncEngine()
    engine.applyPreviewState(
      lastError: .authFailed("Invalid Feedbin credentials"))
    return engine
  }()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntryID: $selectedEntryID,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(AppFontSettings())
    .environment(FaviconStore())
    .modelContainer(container)
    .task {
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` with classification mid-batch, a classified row in
/// ANOTHER category ("world"), and the queried category ("apple") resolving
/// empty. EXPECTATION REVERSED by issue #146 (reverses #137): the pane shows
/// "No Articles" — the calm-loading "Sorting your articles" state is gone. A
/// resolved-empty fetch now asserts emptiness regardless of engine activity,
/// because the deferred-bump drain channel re-fetches as classification lands
/// rows: the moment the first article exists in this category, the list
/// populates live. The false-empty flash #137 guarded against is prevented by
/// mechanism instead — `pending ≠ resolved` in `entryListDisplayState` (the
/// unit truth table pins it). The mid-batch `ClassificationEngine` is still
/// injected on purpose: it documents that engine activity no longer changes
/// this outcome (the view no longer reads it).
@MainActor
private struct EntryListEmptyWhileClassifyingPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = {
    let container = PreviewSupport.makeContainer()
    let context = container.mainContext
    let feed = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "World Feed",
      feedURL: "https://world.example.com/feed", siteURL: "https://world.example.com",
      createdAt: .now)
    context.insert(feed)
    let entry = Entry(
      feedbinEntryID: 1, title: "A World Story", author: "Bot",
      url: "https://world.example.com/1", content: "<p>Story.</p>", summary: "Story",
      extractedContentURL: nil, publishedAt: .now, createdAt: .now)
    entry.feed = feed
    entry.primaryCategory = "world"
    entry.primaryFolder = "news"
    entry.isClassified = true
    entry.plainText = "Story."
    context.insert(entry)
    try? context.save()
    return container
  }()
  private let syncEngine = SyncEngine()
  private let classificationEngine: ClassificationEngine = {
    let engine = ClassificationEngine()
    engine.applyPreviewState(
      isClassifying: true,
      progress: "Categorizing 3/8",
      classifiedCount: 3,
      totalToClassify: 8
    )
    return engine
  }()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntryID: $selectedEntryID,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(classificationEngine)
    .environment(AppFontSettings())
    .environment(FaviconStore())
    .modelContainer(container)
    .task {
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}

/// Renders `EntryListView` in the genuine empty state at rest: no rows, no
/// sync error → the resolved-empty fetch shows "No Articles" (the
/// `.noArticles` case of `entryListDisplayState`).
@MainActor
private struct EntryListEmptyAtRestPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = PreviewSupport.makeContainer()
  private let syncEngine = SyncEngine()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .now.addingTimeInterval(-7 * 86_400),
          reader: reader,
          refreshVersion: 0,
          pinnedFeedbinEntryID: nil,
          selectedEntryID: $selectedEntryID,
          onMarkAllRead: {}
        )
      } else {
        ProgressView()
      }
    }
    .environment(syncEngine)
    .environment(AppFontSettings())
    .environment(FaviconStore())
    .modelContainer(container)
    .task {
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: 360, height: 480)
  }
}
