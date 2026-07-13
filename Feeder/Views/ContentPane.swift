import SwiftData
import SwiftUI
import os.signpost

// MARK: - Content Pane (issue #146 final fix)

/// The middle column: renders the article list for `nav.selection` and OWNS
/// every volatile-navigation read that used to dirty `ContentView.body` —
/// the selection gate, the filter picker, the drain keys, and the
/// click-signpost `@State` cluster (re-homed here so per-click interval
/// writes dirty THIS pane, not the shell). Re-evaluating on a category
/// switch is CORRECT here — the list changes; the point of the split is
/// that ONLY this pane (and the `SidebarInner` leaf) re-evaluates.
struct ContentPane: View {
  /// Hold time before a finished classification batch may refresh the
  /// article list while the user is actively browsing. If any row gained or
  /// lost a category, the `List` rebuild may reseat the scroll anchor —
  /// perceived as "jumping" mid-click. Deferred until the selection has
  /// been stable this long (or cleared).
  fileprivate static let classificationBumpDwell: Duration = .seconds(4)
  /// Idle throttle for classification bumps when no row is selected —
  /// coalesces progress ticks into a calm live-populate cadence (#146).
  fileprivate static let classificationIdleThrottle: Duration = .seconds(1)
  /// Shorter dwell for sync-page bumps: new entries land at the top via
  /// stable-ID diffing, so a near-immediate refresh is non-disruptive; the
  /// dwell buys a coalescing window. Also the sync channel's no-selection
  /// idle throttle.
  fileprivate static let syncBumpDwell: Duration = .milliseconds(750)

  let panelFocus: FocusState<PanelFocus?>.Binding
  let flushPendingReads: () -> Void
  let onMarkAllRead: () -> Void

  @Environment(ReadingSelection.self)
  private var nav
  @Environment(UnreadState.self)
  private var unreadState
  @Environment(SyncEngine.self)
  private var syncEngine
  @Environment(ClassificationEngine.self)
  private var classificationEngine
  @Environment(\.modelContext)
  private var modelContext
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  /// Pending mid-flight refresh flags, drained by the dwell triggers below.
  @State
  private var pendingClassificationBump = false
  @State
  private var pendingSyncBump = false
  /// In-flight click → render signpost states (da rider 1: re-homed from
  /// `ContentView` with their `onChange` sites, so the per-click `@State`
  /// writes dirty this pane instead of the shell). Held in `@State` so the
  /// begin survives the SwiftUI commit boundary to the matching end.
  @State
  private var sidebarClickIntervalState: OSSignpostIntervalState?
  @State
  private var articleClickIntervalState: OSSignpostIntervalState?

  var body: some View {
    @Bindable
    var nav = nav
    Group {
      if let selection = nav.selection {
        entryListForSelection(selection, selectedEntryID: $nav.selectedEntryID)
          .focused(panelFocus, equals: .articleList)
          .environment(\.pendingReadIDs, unreadState.pendingReadIDs)
          .navigationTitle(navigationTitle)
          .toolbar {
            ToolbarItem(placement: .automatic) {
              Picker("Filter", selection: $nav.articleFilter) {
                ForEach(ArticleFilter.allCases, id: \.self) { filter in
                  Text(filter.rawValue).tag(filter)
                }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .accessibilityIdentifier("article.filter")
            }
            ToolbarItem(placement: .automatic) {
              Button {
                onMarkAllRead()
              } label: {
                Image(systemName: "checkmark")
              }
              .disabled(nav.articleFilter == .read)
              .help("Mark all as read (⇧A)")
              .accessibilityIdentifier("toolbar.markAllRead")
            }
          }
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nav.articleFilter)
      } else {
        ContentUnavailableView {
          Label("No Category", systemImage: "newspaper")
        } description: {
          Text("Select a category from the sidebar.")
        }
      }
    }
    .onChange(of: nav.selectedEntryID) { _, _ in
      // SINGLE-WRITER call site — the only one in the app: resolve the
      // memoized live model (O(1) primary-key lookup for exactly one row)
      // and reset the view mode, both inside the model.
      nav.resolveSelectedEntry(in: modelContext)
      // Defer the pending-read insertion off the selection-commit critical
      // path. An in-frame mutation would cascade through the sidebar
      // unread-count aggregation and the EntryRowView dimming overlay
      // (both observe the overlay), nudging row metrics on the same frame
      // the user pressed arrow-down — perceived as keyboard lag.
      // `applyPendingReadAfterYield` yields the selection write first, then
      // mutates next tick. Mark-read reads the LIVE `entry.isRead` —
      // fresher than the row DTO's snapshot.
      if let entry = nav.selectedEntry, !entry.isRead {
        applyPendingReadAfterYield(feedbinEntryID: entry.feedbinEntryID) { id in
          unreadState.insertPendingRead(feedbinEntryID: id)
        }
      }
      // Article-click signpost begin: measures SwiftUI commit cost from
      // writing the selection to the detail column's `.task` firing.
      // No begin when selection clears — empty-state has no render cost.
      if nav.selectedEntry != nil {
        articleClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.articleClick
        )
      }
    }
    .task(id: nav.selectedEntry?.feedbinEntryID) {
      // Article-click signpost end: pairs with the begin above; runs
      // immediately on the next render pass, keeping the measurement
      // bounded to "selection commit ⇒ next SwiftUI render pass".
      guard let state = articleClickIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.articleClick, state)
      articleClickIntervalState = nil
    }
    .onChange(of: nav.articleFilter) {
      flushPendingReads()
      nav.selectedEntryID = nil
    }
    .onChange(of: nav.selection) { _, newSelection in
      flushPendingReads()
      nav.selectedEntryID = nil
      // Sidebar-click signpost begin: measures SwiftUI commit cost from
      // writing `selection` to the content column re-rendering.
      if newSelection != nil {
        sidebarClickIntervalState = perfSignposter.beginInterval(
          PerformanceSignpostName.sidebarClick
        )
      }
    }
    .task(id: nav.selection) {
      // Sidebar-click signpost end: pairs with the begin above — runs
      // immediately on the next render pass and closes the interval.
      guard let state = sidebarClickIntervalState else { return }
      perfSignposter.endInterval(PerformanceSignpostName.sidebarClick, state)
      sidebarClickIntervalState = nil
    }
    // Refresh the article list whenever underlying article data may have
    // changed. Both triggers fire on the false transition (work just
    // finished) and only when the finished batch actually changed rows.
    .onChange(of: syncEngine.isSyncing) { _, isSyncing in
      if !isSyncing && syncEngine.lastSyncChangedEntryCount > 0 {
        unreadState.noteDataChanged()
      }
    }
    .onChange(of: classificationEngine.isClassifying) { _, isClassifying in
      if !isClassifying && classificationEngine.lastBatchClassifiedCount > 0 {
        pendingClassificationBump = true
      }
    }
    // Mid-flight refresh signals: bumped while the underlying job runs
    // (sync per persisted page, classification per throttled progress
    // snapshot); routed into the deferred drain channel so a burst
    // coalesces into a single refresh tick. The router is a leaf view so
    // the engine counters are read inside its own body, not this pane's.
    .modifier(
      MidFlightBumpRouterModifier(
        pendingSyncBump: $pendingSyncBump,
        pendingClassificationBump: $pendingClassificationBump
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: classificationBumpDrainKey,
        dwell: Self.classificationBumpDwell,
        idleThrottle: Self.classificationIdleThrottle,
        hasSelection: nav.selectedEntry != nil,
        pendingBump: $pendingClassificationBump,
        onDrain: { unreadState.noteDataChanged() }
      )
    )
    .modifier(
      DeferredBumpDrainTrigger(
        key: syncBumpDrainKey,
        dwell: Self.syncBumpDwell,
        idleThrottle: Self.syncBumpDwell,
        hasSelection: nav.selectedEntry != nil,
        pendingBump: $pendingSyncBump,
        onDrain: { unreadState.noteDataChanged() }
      )
    )
  }

  // MARK: - Derivations (nav-reading — this pane's own dependencies)

  /// Pure dictionary lookup on the nav model's taxonomy mirror — zero
  /// `@Model` reads (pre-split this searched the `@Query` arrays).
  private var navigationTitle: String {
    guard let selection = nav.selection else { return "Articles" }
    return nav.displayNames[selection] ?? "Articles"
  }

  /// Re-key for the classification drain task. A change in either component
  /// restarts the task: selection move ⇒ fresh dwell window; pending flag
  /// flip ⇒ pick up the newly-owed bump.
  private var classificationBumpDrainKey: String {
    "\(nav.selectedEntry?.feedbinEntryID ?? -1)|\(pendingClassificationBump)"
  }

  /// Sibling of `classificationBumpDrainKey` for the sync-page drain.
  private var syncBumpDrainKey: String {
    "sync|\(nav.selectedEntry?.feedbinEntryID ?? -1)|\(pendingSyncBump)"
  }

  @ViewBuilder
  private func entryListForSelection(
    _ sel: SidebarSelection, selectedEntryID: Binding<PersistentIdentifier?>
  ) -> some View {
    if let reader = syncEngine.reader {
      let (category, folder): (String?, String?) =
        switch sel {
        case .category(let label): (label, nil)
        case .folder(let label): (nil, label)
        }
      EntryListView(
        category: category, folder: folder, filter: nav.articleFilter,
        cutoffDate: syncEngine.queryCutoffDate, reader: reader,
        refreshVersion: unreadState.refreshVersion,
        pinnedFeedbinEntryID: nav.selectedEntry?.feedbinEntryID,
        selectedEntryID: selectedEntryID, onMarkAllRead: onMarkAllRead
      )
    } else {
      // SyncEngine.configure hasn't completed yet (first launch path).
      // The .toolbar, .navigationTitle, .focused etc. modifiers from the
      // call site still apply to this ProgressView since they're chained
      // on the function's return value.
      ProgressView()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
