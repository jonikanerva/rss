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
struct EntryListView: View {
  // MARK: - Paging knobs (issue #151 — owner-trace-gated)
  //
  // All three are calibrated against the owner's post-#148 real-data trace
  // and are adjustable ONLY against the owner's next re-trace — do not tune
  // them from the synthetic harness.

  /// Rows rendered on a structural reload — the bounded first paint that
  /// kills the giant-category render hang. Band math from the p90 trace:
  /// the worst-category structural commit measured ~0.3–0.5 ms/row; a cold
  /// render runs ×2–4 that band, so 100 rows ⇒ ≤ ~200 ms first paint —
  /// under the 250 ms hang bar with headroom.
  static let initialRowLimit = 100
  /// Rows added per append request. Larger than the initial cap on purpose:
  /// follow-up appends happen while content is already on screen, so their
  /// commit cost is not a blank-pane wait.
  static let rowLimitGrowthStep = 200
  /// The append fires when the row this many positions before the window end
  /// appears, so the grown refetch usually lands before the user reaches the
  /// bottom. Also self-heals the top-insert edge: rows a sync page pushes
  /// past the window bottom re-trigger the append when the (shifted) trigger
  /// row scrolls in.
  static let appendTriggerMargin = 20

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
  /// Current fetch-window size (issue #151). Reset to `initialRowLimit` in
  /// the structural task's synchronous prefix; RETAINED across refresh ticks
  /// (a sync/classification bump re-fetches at the grown size, so the list
  /// never shrinks back under the user); only ever grows within one
  /// structural context — via `requestAppend()` or pin-coverage adoption.
  @State
  private var rowLimit = Self.initialRowLimit
  /// True when the last fetch filled its whole window — the store may hold
  /// more rows (`hasMorePages`; total == limit is a benign false positive
  /// that settles after one no-op grow).
  @State
  private var hasMore = false
  /// The row whose appearance requests the next append — precomputed by the
  /// reader (`margin` rows before the window end); nil when nothing more to
  /// append. The row `.onAppear` does an O(1) id compare against this.
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
                  .onAppear {
                    // Lazy-append trigger (issue #151): an O(1) id compare
                    // against the reader-precomputed trigger row — no index
                    // math or window arithmetic in per-row render code. The
                    // trigger row carries no visible chrome; VoiceOver
                    // semantics are unchanged.
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
        // C3 perception/occupancy (issue #138): bracket the panel-2 blank
        // window (structural key change → sections replaced). `defer` closes
        // it even if the task is cancelled mid-reload by a structural-key
        // change.
        //
        // NOTE (issue #151): this bracket closes at the STATE WRITE, before
        // SwiftUI's commit/layout — the first-paint render cost lands
        // OUTSIDE the interval. Judge first-paint behaviour via hang
        // reports / time-profile in the owner's trace, not this bracket
        // alone.
        let signpost = perfSignposter.beginInterval(PerformanceSignpostName.structuralReload)
        defer { perfSignposter.endInterval(PerformanceSignpostName.structuralReload, signpost) }
        // Synchronous prefix: enter the pending phase, drop the previous
        // context's rows before the first await (the pane never shows the
        // old category's rows while the new fetch runs), and reset the fetch
        // window to the initial cap — a different list starts from its own
        // bounded first page (issue #151).
        fetchPhase = .pending
        sections = []
        visibleEntries = .empty
        rowLimit = Self.initialRowLimit
        hasMore = false
        appendTriggerID = nil
        if await reload(proxy: proxy) {
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
        if await reload(proxy: proxy) {
          fetchPhase = .resolved
        }
      }
      .onChange(of: selectedEntryID) { _, newID in
        // Keyboard append (issue #151): arrow-key selection can reach the
        // last fetched row without the append-trigger row ever scrolling
        // through `.onAppear` (selection moves faster than lazy row
        // materialization) — grow the window when the selection lands on
        // the window's last row.
        if let newID, newID == visibleEntries.ids.last { requestAppend() }
      }
    }
  }

  /// Grow the fetch window by one step (issue #151).
  ///
  /// CONTRACT (binding, da rider 2): growth ALWAYS refetches the grown
  /// prefix atomically — `rowLimit` joins `refreshTaskKey`, so the bump
  /// restarts the SwiftUI-owned refresh task, which re-runs the reader fetch
  /// at the grown size. Cached tail DTOs are never revealed: appended rows
  /// are COMMITTED state from a fresh query, which is what keeps the
  /// two-sided pending-read prune correct. The `ids.count == rowLimit` guard
  /// stops growth loops when the store holds fewer rows than the window
  /// (the benign `hasMore` false positive settles here).
  private func requestAppend() {
    guard hasMore, visibleEntries.ids.count == rowLimit else { return }
    rowLimit = nextRowLimit(current: rowLimit, growthStep: Self.rowLimitGrowthStep)
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

  /// Fetch and apply the sections for the current context. Returns `true`
  /// when the fetch resolved and its result was applied (or was identical, so
  /// no apply was needed); `false` on failure or cancellation — callers
  /// distinguish the two via `Task.isCancelled` before treating `false` as a
  /// store failure.
  private func reload(proxy: ScrollViewProxy) async -> Bool {
    let result: EntryListFetchResult
    do {
      result = try await reader.fetchEntrySections(
        category: category, folder: folder, showRead: filter == .read,
        cutoffDate: cutoffDate, pinnedFeedbinEntryID: pinnedFeedbinEntryID,
        paging: EntryListPageRequest(
          limit: rowLimit,
          appendTriggerMargin: Self.appendTriggerMargin,
          previousVisibleIDs: visibleEntries.ids
        )
      )
    } catch is CancellationError {
      // Silent exit — neither success nor failure. The reader's
      // `Task.checkCancellation` guard surfaces here when a structural-key
      // change cancels a queued stale fetch.
      return false
    } catch {
      // Store error — logged once per failure, here so both callers share
      // it. The structural task shows the error pane; a failed refresh keeps
      // the previous phase (existing rows or the error pane).
      logger.error(
        "Article-list fetch failed for \(category ?? folder ?? "none", privacy: .private)"
      )
      return false
    }
    guard !Task.isCancelled else { return false }
    // Paging outputs land BEFORE the sections-equal early-out: a no-op grow
    // (store total < grown window) leaves the rows identical but must still
    // settle `hasMore` to false. Pin-coverage adoption only ever grows the
    // window; the `rowLimit` write re-keys the refresh task, costing one
    // sections-equal no-op refetch — accepted for the single-writer shape.
    if let effective = result.effectiveLimit, effective > rowLimit {
      rowLimit = effective
    }
    hasMore = result.hasMore
    appendTriggerID = result.appendTriggerID
    guard result.sections != sections else { return true }
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
    let newIDs = Set(result.allEntryIDs)
    let restore: AnchorRestore?
    if result.isPrefixExtension {
      // Pure tail append (issue #151): every previously rendered row kept
      // its position, so any restore scroll would only fight the user's
      // momentum at the moment they are scrolling toward the new rows.
      // The flag is computed reader-side so this costs MainActor nothing.
      restore = nil
    } else if let selectedID = selectedEntryID, newIDs.contains(selectedID) {
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
    sections = result.sections
    visibleEntries = VisibleEntriesPayload(
      ids: result.allEntryIDs,
      unreadFeedbinEntryIDs: result.renderedUnreadFeedbinEntryIDs
    )
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

  /// Composed key for the refresh task so a structural change (category /
  /// folder / filter / cutoff) cancels any in-flight refresh bound to the
  /// previous context. Without the structural suffix, a refresh captured
  /// against the old `self` could finish after the structural reload and
  /// overwrite `sections` with stale rows. `rowLimit` joins the key (issue
  /// #151) so an append request re-fires this SwiftUI-owned task — the
  /// growth mechanism IS the existing refresh machinery: cancellable,
  /// structural-change-safe, no new task type.
  private var refreshTaskKey: String {
    "\(structuralKey)|\(refreshVersion)|\(rowLimit)"
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

#Preview("Giant Category — Capped") {
  EntryListGiantCategoryPreview()
}

/// Renders `EntryListView` over a ~300-row category (issue #151): the first
/// paint shows only `initialRowLimit` rows — the bounded window that kills
/// the giant-category render hang — and scrolling past the trigger row (or
/// arrow-keying onto the window's last row) grows the window by
/// `rowLimitGrowthStep` via an atomic grown-prefix refetch. Canonical
/// newest-first order throughout; growth only appends.
@MainActor
private struct EntryListGiantCategoryPreview: View {
  @State
  private var reader: DataReader?
  @State
  private var selectedEntryID: PersistentIdentifier?
  private let container: ModelContainer = {
    let container = PreviewSupport.makeContainer()
    let context = container.mainContext
    let feed = Feed(
      feedbinSubscriptionID: 1, feedbinFeedID: 1, title: "Giant Feed",
      feedURL: "https://giant.example.com/feed", siteURL: "https://giant.example.com",
      createdAt: .now)
    context.insert(feed)
    let newest = Date.now
    for offset in 0..<300 {
      let entry = Entry(
        feedbinEntryID: 10_000 + offset, title: "Giant category story \(offset)",
        author: nil, url: "https://giant.example.com/\(offset)",
        content: "<p>Story \(offset).</p>", summary: "Story \(offset).",
        extractedContentURL: nil,
        publishedAt: newest.addingTimeInterval(-Double(offset) * 600), createdAt: newest)
      entry.feed = feed
      entry.primaryCategory = "apple"
      entry.primaryFolder = "tech"
      entry.isClassified = true
      entry.plainText = "Story \(offset)."
      entry.summaryPlainText = "Story \(offset)."
      entry.formattedPublishedTime = "09.30"
      entry.displayDomain = "giant.example.com"
      context.insert(entry)
    }
    try? context.save()
    return container
  }()
  private let syncEngine = SyncEngine()

  var body: some View {
    Group {
      if let reader {
        EntryListView(
          category: "apple",
          folder: nil,
          filter: .unread,
          cutoffDate: .distantPast,
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
    .frame(width: 360, height: 600)
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
