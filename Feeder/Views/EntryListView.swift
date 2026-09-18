import SwiftData
import SwiftUI
import os
import os.signpost

/// Flags an article-list fetch failure (a store error thrown by the reader).
/// One error line per failure; the category / folder label is user-derived
/// taxonomy, so it is interpolated `.private` (`STACK.md § 8`).
private let logger = Logger(subsystem: "com.feeder.app", category: "EntryListView")

// MARK: - Visible Entries Preference Key

/// Payload for `VisibleEntriesKey`: the rendered entry ids plus the
/// rendered-unread feedbin ids, which form the rendered side of the two-sided
/// `pendingReadIDs` retention prune. Both aggregates are computed off-main by
/// `DataReader.fetchEntrySections`; the view only bubbles them.
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

// MARK: - Entry List View

/// Renders the article list for a given sidebar selection.
///
/// The fetch, projection, and grouping run on `DataReader`, never as a
/// MainActor `@Query`: a large category blocks the main thread for seconds.
/// Rows are complete `EntryRowDTO` snapshots, so no row touches the store on
/// MainActor. Selection carries the row's `PersistentIdentifier`, and
/// `ContentView` resolves the one full `Entry` at the detail boundary.
///
/// The `List` stays mounted across reloads: every state except the empty
/// family renders it, and a pending window renders it with zero rows. A
/// spinner branch or a separate blank branch would remount the `List` and
/// rebuild every row. "No Articles" is asserted only by a resolved empty
/// fetch, never while a fetch is pending and never while rows exist.
///
/// Refreshes arrive only as explicit version bumps from `ContentView`, each
/// under the post-commit contract on `bumpEntryList`.
///
/// The view holds a bounded window of the canonical order, defined by the
/// cursor of its last loaded row: structural fetches take `firstPage`,
/// refreshes `atOrAbove`, appends `after`. Paging tiles the same sorted
/// result, so nothing is reordered or hidden
/// (`VISION.md → Core Principles`).
struct EntryListView: View {
  let category: String?
  let folder: String?
  let filter: ArticleFilter
  let cutoffDate: Date
  let reader: DataReader
  let refreshVersion: Int
  /// When non-nil, the row with this Feedbin entry ID stays in the fetch
  /// result regardless of the filter, so a selected article stays visible
  /// after a cross-device read-state flip. The pin rides along with the next
  /// refresh trigger; a selection change alone does not re-fetch.
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
  /// Computed once per fetch by the reader; never walk `sections` in `body`.
  @State
  private var visibleEntries: VisibleEntriesPayload = .empty
  /// Fetch lifecycle for the current structural context. Drives
  /// `entryListDisplayState(...)` together with `sections`.
  @State
  private var fetchPhase: FetchPhase = .pending
  /// Whether the store holds eligible rows below the loaded window. Exact —
  /// see `EntryListFetchResult.hasMore`. Gates the append triggers, and the
  /// structural prefix resets it.
  @State
  private var hasMore = false
  /// Append channel version: bumping it re-keys the append `.task`, which
  /// fetches one `after(cursor, limit:)` page. The task id also embeds
  /// `structuralKey`, so a category switch cancels an in-flight append.
  @State
  private var appendVersion = 0
  /// One append in flight at a time: the trigger paths may fire repeatedly
  /// while a page fetch runs, and must not stack version bumps.
  @State
  private var isAppending = false
  /// The row whose appearance requests the next append, `appendTriggerMargin`
  /// rows before the window end. Precomputed once per apply; never derive it
  /// in `body`. `nil` when there is nothing more to load.
  @State
  private var appendTriggerID: PersistentIdentifier?
  /// Which structural context the loaded window belongs to. The structural
  /// task's synchronous prefix clears it and takes ownership of the window;
  /// resolve and failure both set it back. `refreshTaskKey` embeds it, so that
  /// flip re-fires the refresh task once and a bump that arrived mid-fetch
  /// reaches the gate instead of being dropped.
  @State
  private var resolvedStructuralKey = ""
  /// The `refreshVersion` already covered by a fetch. The structural task
  /// snapshots it immediately before its first-page fetch; a successful
  /// refresh records the version it consumed. The gate skips a refresh whose
  /// version is already consumed.
  @State
  private var consumedRefreshVersion = 0
  /// Carries the anchor row and alignment from the pre-diff inspection to the
  /// post-diff `proxy.scrollTo` call. State, because producer and consumer sit
  /// in one async function but bracket the `sections` assignment.
  @State
  private var pendingAnchorRestore: AnchorRestore?

  /// Anchor and alignment pair for `ScrollViewReader.scrollTo`. `.center`
  /// keeps a still-selected row visible after a filter flip or a reshuffle;
  /// `.top` keeps the first row pinned when a sync page lands rows above it.
  private struct AnchorRestore: Equatable {
    let id: PersistentIdentifier
    let anchor: UnitPoint
  }

  /// Debounce window for a structural navigation change. Coalesces a rapid
  /// J/K burst into one reload: an intermediate keypress cancels the prior
  /// `.task(id: structuralKey)` during this sleep, before it can blank the
  /// pane or queue a fetch on the serial `DataReader` actor.
  private static let navDebounce: Duration = .milliseconds(150)

  /// Keyset page size: the first page and every appended page load this many
  /// rows. Deliberately not a preference — one opinionated way
  /// (`VISION.md → Non-Goals`).
  private static let pageSize = 100

  /// How many rows before the window end the append-trigger row sits, so the
  /// next page usually lands before the user reaches the bottom by scroll or
  /// by J/K. Never a preference.
  private static let appendTriggerMargin = 20

  var body: some View {
    // `ScrollViewReader` lives OUTSIDE the conditional `Group`, so the `.task`
    // modifiers attach to its body and stay mounted for the view's lifetime,
    // not for whichever branch is selected. `proxy.scrollTo(_:anchor:)`
    // resolves `.id(...)` tags anywhere in its subtree, so the rows below
    // stay reachable.
    ScrollViewReader { proxy in
      Group {
        // The empty family renders only when a resolved or failed fetch left
        // zero sections; every other state renders the same mounted `List`.
        // `.blank` shares the `List` branch on purpose — a separate branch
        // would remount the `List` on every structural reload.
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
                // Rows render straight from their DTO snapshots: zero store
                // access on MainActor. The favicon is a dictionary lookup;
                // the decode happened once in `FaviconStore`.
                ForEach(section.rows) { row in
                  EntryRowView(
                    row: row,
                    faviconImage: faviconStore.image(for: row.feedFeedbinID)
                  )
                  .tag(row.persistentID)
                  .id(row.persistentID)
                  .listRowSeparator(.hidden)
                  // Zero vertical inset: the row's own padding carries the
                  // rhythm, so the table's row height equals the row content
                  // height and the floor below matches it exactly.
                  .listRowInsets(
                    EdgeInsets(
                      top: 0, leading: EntryRowMetrics.horizontalInset,
                      bottom: 0, trailing: EntryRowMetrics.horizontalInset)
                  )
                  // The trigger row's appearance fires for scroll and for
                  // J/K navigation alike. Keep this a plain id comparison —
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
          // Row-height floor: `List` bounds row height below by
          // `defaultMinListRowHeight`. Set it to the row's natural height, so
          // a re-measure that falls back to the platform default has nothing
          // left to clip. The row itself carries no `.frame(height:)`, so this
          // stays a floor and never becomes a cap. Scoped to this `List`; the
          // sidebar keeps the system value.
          .environment(\.defaultMinListRowHeight, fontSettings.entryRowHeight)
          .modifier(BareKeyHandler())
          .modifier(MarkAllReadKeyHandler(action: onMarkAllRead))
          .preference(key: VisibleEntriesKey.self, value: visibleEntries)
          .accessibilityIdentifier("timeline.list")
        }
      }
      // Two tasks, so a refresh-only tick does not re-run the structural path
      // and drop the rows to a blank pane. `structuralKey` captures the
      // inputs whose change means the user is looking at a different list;
      // only those clear the previous rows.
      .task(id: structuralKey) {
        // Keep the debounce at the very top — before the signpost, the
        // `.pending` prefix, and the fetch — so an intermediate keypress
        // exits here during the cheap sleep: no blanked pane and no fetch
        // queued on the serial `DataReader` actor. `try?` swallows the
        // sleep's `CancellationError`, so the explicit `Task.isCancelled`
        // re-check is what makes a cancelled burst step a no-op.
        try? await Task.sleep(for: Self.navDebounce)
        guard !Task.isCancelled else { return }
        // Bracket the blank window, from the structural key change to the
        // replaced sections. `defer` closes the interval even when a
        // structural-key change cancels the task mid-reload.
        let signpost = perfSignposter.beginInterval(PerformanceSignpostName.structuralReload)
        // Read at `defer` time, after `reload` has assigned `visibleEntries`.
        // Row count and category label only; no PII (`STACK.md § 8`).
        defer {
          perfSignposter.endInterval(
            PerformanceSignpostName.structuralReload, signpost,
            "rows=\(visibleEntries.ids.count, privacy: .public) cat=\(category ?? folder ?? "unified", privacy: .private)"
          )
        }
        // Synchronous prefix: enter the pending phase and drop the previous
        // context's rows before the first await, so the pane never shows the
        // old category's rows while the new fetch runs. Clearing
        // `resolvedStructuralKey` hands window ownership to this task, and the
        // refresh gate stands down until resolve or failure flips it back.
        fetchPhase = .pending
        sections = []
        visibleEntries = .empty
        hasMore = false
        appendTriggerID = nil
        appendVersion = 0
        isAppending = false
        resolvedStructuralKey = ""
        // Snapshot before the fetch: a bump landing above this line is
        // covered by the first-page fetch below, and a bump landing after it
        // stays owed and re-fires on the resolve flip. A bump racing the
        // fetch costs one redundant refresh, never a dropped update.
        let preFetchRefreshVersion = refreshVersion
        if await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy) {
          fetchPhase = .resolved
          consumedRefreshVersion = preFetchRefreshVersion
          resolvedStructuralKey = structuralKey
          return
        }
        guard !Task.isCancelled else { return }
        // No retry: the shared coordinator blocks rather than throws under
        // contention (`STACK.md § 14`), so a fetch throw is almost certainly
        // persistent. Healing is free — any refresh bump re-fetches, and the
        // gate deliberately lets `.failed` pass.
        fetchPhase = .failed
        consumedRefreshVersion = preFetchRefreshVersion
        resolvedStructuralKey = structuralKey
      }
      .task(id: refreshTaskKey) {
        // Skip when the structural task owns the window, or when a fetch
        // already covered this version. A successful refresh records the
        // version it consumed; a failed or cancelled refresh leaves it owed.
        guard
          shouldRunWindowRefresh(
            resolvedKey: resolvedStructuralKey, currentKey: structuralKey,
            phase: fetchPhase, refreshVersion: refreshVersion,
            consumedVersion: consumedRefreshVersion)
        else { return }
        let version = refreshVersion
        if await refresh(proxy: proxy) {
          fetchPhase = .resolved
          consumedRefreshVersion = version
        }
      }
      // Its own task, so an append neither debounces like the structural path
      // nor replaces the window like the refresh path. The id embeds
      // `structuralKey`, so a category switch cancels an in-flight append.
      .task(id: appendTaskKey) {
        guard isAppending else { return }
        await appendNextPage()
        isAppending = false
      }
      // End and Page-Down can land the selection on the last loaded row
      // without the trigger row's `onAppear` ever firing, because `List` may
      // skip materialising the rows in between.
      .onChange(of: selectedEntryID) { _, newValue in
        if let newValue, newValue == visibleEntries.ids.last {
          requestAppend()
        }
      }
    }
  }

  /// Single derivation point for what the pane shows — the pure precedence
  /// rule in `Helpers/EntryListDisplayState.swift`.
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
      // Neither success nor failure: the reader's `Task.checkCancellation`
      // guard surfaces here when a structural-key change cancels a queued
      // stale fetch.
      return nil
    } catch {
      // Logged once per failure, here, so every caller shares the line.
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

  /// Whole-window refresh: refetch everything at or above the loaded window's
  /// bottom edge in one snapshot, so new rows land above, read-state flips
  /// land in place, and the appended tail survives.
  ///
  /// The snapshot applies only if the window's bottom edge still equals the
  /// cursor the fetch started from; otherwise an append landing mid-refresh
  /// would be wiped by the older snapshot. On mismatch the result is discarded
  /// and the refresh re-fires against the current cursor.
  private func refresh(proxy: ScrollViewProxy) async -> Bool {
    while !Task.isCancelled {
      // Re-gate on every iteration: the cursor-mismatch `continue` below can
      // loop while a structural prefix has already cleared the window, and
      // without this check the retry races the structural task's own
      // first-page fetch.
      guard
        shouldRunWindowRefresh(
          resolvedKey: resolvedStructuralKey, currentKey: structuralKey,
          phase: fetchPhase, refreshVersion: refreshVersion,
          consumedVersion: consumedRefreshVersion)
      else { return false }
      guard let fetchStartCursor = entryListCursor(of: sections) else {
        // Nothing loaded: a refresh from an empty window is just a first
        // page, so the category's first row appears without user action.
        return await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy)
      }
      let window = EntryListWindow.atOrAbove(fetchStartCursor)
      guard let result = await fetchResult(window: window) else { return false }
      guard !Task.isCancelled else { return false }
      guard entryListCursor(of: sections) == fetchStartCursor else { continue }
      // Every loaded row left the filter, so run one first-page fetch and
      // surface the rows below the window instead of a false "No Articles".
      if refreshRequiresFirstPageFallback(window: window, result: result) {
        return await reload(window: .firstPage(limit: Self.pageSize), proxy: proxy)
      }
      return await apply(result, proxy: proxy)
    }
    return false
  }

  /// Apply a fetched first-page or refresh snapshot: diff-skip, anchor
  /// restore, state assignment, favicon warm, paging-state update. Appends go
  /// through `appendNextPage`, which extends the tail and never restores an
  /// anchor.
  private func apply(_ result: EntryListFetchResult, proxy: ScrollViewProxy) async -> Bool {
    let diffSignpost = perfSignposter.beginInterval(PerformanceSignpostName.reloadDiff)
    let sectionsUnchanged = result.sections == sections
    perfSignposter.endInterval(PerformanceSignpostName.reloadDiff, diffSignpost)
    guard !sectionsUnchanged else {
      // The rows are identical, but the universe below the window may have
      // changed — keep the append gate exact. Guarded assignment, so an
      // unchanged refresh does not dirty the view.
      if hasMore != result.hasMore {
        hasMore = result.hasMore
        updateAppendTrigger(allIDs: result.allEntryIDs, hasMore: result.hasMore)
      }
      return true
    }
    // Pin an anchor only where a restore is warranted: the selected row still
    // appears, so keep it centred through a row-height shift; or the
    // selection is clear and the previously-first row still appears, so keep
    // the top stable when a sync page lands rows above it. A structural
    // reload pins nothing, so no anchor comes from the previous list.
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
    let assignSignpost = perfSignposter.beginInterval(PerformanceSignpostName.reloadStateAssign)
    sections = result.sections
    visibleEntries = VisibleEntriesPayload(
      ids: result.allEntryIDs,
      unreadFeedbinEntryIDs: result.renderedUnreadFeedbinEntryIDs
    )
    hasMore = result.hasMore
    updateAppendTrigger(allIDs: result.allEntryIDs, hasMore: result.hasMore)
    perfSignposter.endInterval(PerformanceSignpostName.reloadStateAssign, assignSignpost)
    // Yield one tick so SwiftUI applies the diff before the proxy scrolls:
    // without it `scrollTo` runs against the old layout. Instant scroll, no
    // `withAnimation`, so the restore respects Reduce Motion.
    if let restore = pendingAnchorRestore {
      pendingAnchorRestore = nil
      await Task.yield()
      proxy.scrollTo(restore.id, anchor: restore.anchor)
    }
    // Warm the favicon cache after the rows are applied and in the same
    // SwiftUI task, so a structural-key change cancels the warm with the
    // reload. Best-effort: a warm failure never fails the reload.
    await faviconStore.ensureLoaded(feedIDs: result.distinctFeedIDs) { ids in
      try await reader.fetchFaviconData(feedbinFeedIDs: ids)
    }
    return true
  }

  /// Request the next append page. Gated on `hasMore` and on one append at a
  /// time; the bump re-keys the append `.task`, which owns the fetch.
  private func requestAppend() {
    guard hasMore, !isAppending else { return }
    isAppending = true
    appendVersion &+= 1
  }

  /// Fetch one `after(cursor, limit:)` page below the window's bottom edge and
  /// extend the window with it. Pure tail insertion: row identity is untouched
  /// and a same-day section extends under its existing id, so the `List` diff
  /// never moves a rendered row and the append needs no anchor restore, scroll,
  /// or animation.
  private func appendNextPage() async {
    guard let fetchStartCursor = entryListCursor(of: sections) else { return }
    guard let page = await fetchResult(window: .after(fetchStartCursor, limit: Self.pageSize))
    else { return }
    guard !Task.isCancelled else { return }
    // Apply only if the window's bottom edge is still the cursor this page was
    // fetched from: a refresh or structural reload landing mid-append would
    // otherwise glue a stale tail onto a fresh snapshot. Discarding is safe —
    // the trigger row is still near the bottom and re-requests.
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
    // Deep pages would otherwise render permanent initials fallbacks: the
    // reload path warms only the pages it fetched itself.
    await faviconStore.ensureLoaded(feedIDs: page.distinctFeedIDs) { ids in
      try await reader.fetchFaviconData(feedbinFeedIDs: ids)
    }
  }

  /// Precompute the append-trigger row id once per apply, so the per-row
  /// `onAppear` check in `body` stays a plain id comparison.
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

  /// Composed key for the refresh task, so a structural change cancels an
  /// in-flight refresh bound to the previous context: without the structural
  /// suffix a refresh could finish after the structural reload and overwrite
  /// `sections` with stale rows. `resolvedStructuralKey` is a component, so
  /// the structural task's resolve flip re-fires the refresh task and a bump
  /// that arrived mid-fetch reaches the gate. Composition is pinned by
  /// `WindowRefreshGateTests`.
  private var refreshTaskKey: String {
    Self.composeRefreshTaskKey(
      structuralKey: structuralKey, resolvedStructuralKey: resolvedStructuralKey,
      refreshVersion: refreshVersion)
  }

  /// Pure key builder behind `refreshTaskKey`, extracted so tests can pin its
  /// composition.
  nonisolated static func composeRefreshTaskKey(
    structuralKey: String, resolvedStructuralKey: String, refreshVersion: Int
  ) -> String {
    "\(structuralKey)|\(resolvedStructuralKey)|\(refreshVersion)"
  }

  /// Composed key for the append task, with the same structural suffix as
  /// `refreshTaskKey`: a category switch cancels an in-flight append.
  private var appendTaskKey: String {
    "\(structuralKey)|append|\(appendVersion)"
  }

  /// Key for "this is a different article list". Excludes `refreshVersion`,
  /// which rides on a separate task so an in-place refresh does not tear down
  /// the `List` and drop the scroll position.
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

// Row matrix: the row-height floor and the title / summary split at every
// text size, in a 320-pt content column and at the 200-pt and 600-pt
// extremes. Every row must be exactly `entryRowHeight` tall. The seeded
// shapes cover a wrapped title, a missing domain, an empty-string domain, an
// empty excerpt, the three-line threshold and one word past it, a read and
// unread twin, an emoji title, and a long domain.

#Preview("Row Matrix - Small") {
  EntryListRowMatrixPreview(textSize: .small)
}

#Preview("Row Matrix - Medium") {
  EntryListRowMatrixPreview(textSize: .medium)
}

#Preview("Row Matrix - Large") {
  EntryListRowMatrixPreview(textSize: .large)
}

#Preview("Row Matrix - Extra Large") {
  EntryListRowMatrixPreview(textSize: .xLarge)
}

#Preview("Row Matrix - Huge") {
  EntryListRowMatrixPreview(textSize: .xxLarge)
}

#Preview("Row Matrix - Medium, Dark") {
  EntryListRowMatrixPreview(textSize: .medium)
    .preferredColorScheme(.dark)
}

#Preview("Row Matrix - Medium, 600 pt") {
  EntryListRowMatrixPreview(textSize: .medium, width: 600)
}

#Preview("Row Matrix - Medium, 200 pt") {
  EntryListRowMatrixPreview(textSize: .medium, width: 200)
}

/// Seeds the row shapes above and renders `EntryListView` at the given
/// content-column width and text size. Row 1010 is unread in the store but
/// sits in `pendingReadIDs`, so it renders as read inside the unread filter.
@MainActor
private struct EntryListRowMatrixPreview: View {
  let textSize: AppTextSize
  var width: CGFloat = 320
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = {
    let container = PreviewSupport.makeContainer()
    let context = container.mainContext
    let feed = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "Matrix Feed",
      feedURL: "https://matrix.example.com/feed", siteURL: "https://matrix.example.com",
      createdAt: .now)
    context.insert(feed)
    let longExcerpt =
      "A long excerpt that runs past the summary budget at every text size and every column width, "
      + "so the last summary line ends with an ellipsis and the split between the title and the "
      + "summary is visible: three lines under a one-line title, two lines under a two-line title, "
      + "and the row height does not change."
    // This exact text fills three lines at medium / 320 pt; one more word
    // pushes it onto a fourth, so 1008 shows an ellipsis.
    let threeLineExcerpt =
      "The excerpt fills the third line to its last word so the row shows three full lines and no "
      + "ellipsis at the medium text size in a"
    let twinTitle = "Twin rows, unread above and read below"
    let twinExcerpt = "The weight swap to regular changes neither the row height nor the split."
    let shapes: [(id: Int, title: String, domain: String?, excerpt: String)] = [
      (1001, "One-line title", "matrix.example.com", longExcerpt),
      (1002, "A title long enough to wrap onto a second line in a narrow column", "matrix.example.com", longExcerpt),
      (
        1003,
        "A title so long that it runs past the second line and has to end with an ellipsis while the time stays top-right",
        "matrix.example.com", longExcerpt
      ),
      (1004, "No domain on this row", nil, longExcerpt),
      (1005, "Empty excerpt, one-line title", "matrix.example.com", ""),
      (1006, "Empty excerpt under a title that wraps onto a second line", "matrix.example.com", ""),
      (1007, "Threshold: three full lines", "matrix.example.com", threeLineExcerpt),
      (1008, "Threshold plus one word", "matrix.example.com", threeLineExcerpt + " column"),
      (1009, twinTitle, "matrix.example.com", twinExcerpt),
      (1010, twinTitle, "matrix.example.com", twinExcerpt),
      (1011, "Emoji in the title 🚀 may cost a summary line", "matrix.example.com", longExcerpt),
      (
        1012, "Long domain truncates in the middle", "a-very-long-subdomain.of-an-even-longer-domain.example.com",
        longExcerpt
      ),
      (1013, "Empty-string domain in the store under a title that wraps onto a second line", "", longExcerpt),
    ]
    for (offset, shape) in shapes.enumerated() {
      let published = Date.now.addingTimeInterval(-Double(offset + 1) * 600)
      let entry = Entry(
        feedbinEntryID: shape.id, title: shape.title, author: "Bot",
        url: "https://matrix.example.com/\(shape.id)", content: "<p>\(shape.excerpt)</p>",
        summary: shape.excerpt, extractedContentURL: nil, publishedAt: published, createdAt: published)
      entry.feed = feed
      entry.primaryCategory = "apple"
      entry.primaryFolder = "technology"
      entry.isClassified = true
      entry.formattedDate = formatEntryDate(published)
      entry.formattedPublishedTime = formatEntryTime(published)
      entry.displayDomain = shape.domain
      entry.plainText = shape.excerpt
      entry.summaryPlainText = shape.excerpt
      context.insert(entry)
    }
    try? context.save()
    return container
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
    .environment(\.pendingReadIDs, [1010])
    .environment(SyncEngine())
    .environment(AppFontSettings(textSize: textSize))
    .environment(FaviconStore())
    .modelContainer(container)
    .task {
      reader = await DataReader.makeDetached(modelContainer: container)
    }
    .frame(width: width, height: 1400)
  }
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
/// another category, and the queried category resolving empty. The pane shows
/// "No Articles": a resolved-empty fetch asserts emptiness regardless of
/// engine activity, and the drain channel re-fetches as classification lands
/// rows. The mid-batch engine is injected on purpose, to show that engine
/// activity does not change this outcome.
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
