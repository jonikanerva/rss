import os
import os.signpost

// MARK: - Shared OSSignposter

/// Shared `OSSignposter` for click → render intervals at hot UI boundaries.
///
/// The subsystem matches the rest of the app per `STACK.md § 8 Logging & privacy`,
/// and the category is the system-recognised `.pointsOfInterest` so
/// Instruments surfaces these intervals under the default "Points of
/// Interest" lane (Logging template) without any extra configuration.
///
/// `OSSignposter` produces zero work when no profiler is attached, so the
/// begin/end calls ride for free in shipping builds — no `#if DEBUG` gating.
/// `nonisolated` so it is callable from any actor context (the detail-pane
/// render path crosses MainActor and a detached task).
nonisolated let perfSignposter = OSSignposter(
  subsystem: "com.feeder.app",
  category: .pointsOfInterest
)

/// Sibling logger used only to flag mis-paired signpost intervals — a begin
/// taken while a previous begin was still un-ended. The misuse is recorded as
/// a debug-level entry so it surfaces under `os_log` filtering without
/// polluting production logs. Subsystem matches `perfSignposter` per
/// `STACK.md § 8 Logging & privacy`; category is human-readable so the warnings are
/// easy to grep for in `log stream`.
nonisolated let perfSignpostLogger = Logger(
  subsystem: "com.feeder.app",
  category: "PerformanceSignposts"
)

// MARK: - Interval names

/// Named entry points for the three click → render intervals we instrument.
///
/// Static strings live in a single namespace so Instruments shows stable,
/// legible labels in the Points of Interest lane and renames stay in one
/// place if the surfaces are reshuffled. See `ContentView` for sidebar
/// and article intervals; `EntryDetailView` for the detail render interval.
///
/// `nonisolated` because the statics are immutable `StaticString` constants —
/// callers cross MainActor (`ContentView` signpost handlers) and nonisolated
/// actor contexts (`PerfSignpostTests` measure-blocks, off-MainActor render
/// tasks) interchangeably, and there is no isolation invariant to enforce.
nonisolated enum PerformanceSignpostName {
  /// Sidebar selection commit → article-list `.task(id: selection)` fires.
  /// Measures the SwiftUI commit cost between writing `selection` and the
  /// content column re-rendering.
  static let sidebarClick: StaticString = "sidebar-click"
  /// Article-row selection commit → detail-pane `.task` fires. Measures the
  /// SwiftUI commit cost between writing `selectedEntry` and the detail
  /// column re-rendering.
  static let articleClick: StaticString = "article-click"
  /// `ArticleWebContainer.task(id: renderKey)` start → `renderedHTML` write
  /// (just before the WKWebView receives `loadHTMLString`). Measures the
  /// off-MainActor render itself, separate from the click → task latency.
  static let detailRender: StaticString = "detail-render"
  /// Perf-scenario nav window: brackets the interleaved keyboard/mouse
  /// navigation pass that `PerfScenarioRunner` drives WHILE a fixed-count
  /// write-pressure task hammers the store. Seeding and cold start happen
  /// BEFORE `beginInterval`, so they are excluded from the interval. The
  /// perf parser reads this interval's `[start, end]` from the trace and
  /// windows the hang counts to it, so the raw under-load stutter count is
  /// readable instead of buried in the once-per-launch cold-start hang.
  /// Only emitted under `FEEDER_PERF_MODE`; a no-op in shipping launches.
  static let perfNavWindow: StaticString = "perf-nav-window"

  // MARK: - C3 read-starvation instrumentation (issue #138)
  //
  // Four intervals that attribute the cold-start / large-sync read-starvation
  // question: does a dense sync-page write burst saturate the shared SwiftData
  // coordinator and starve the article-list read? All ride `perfSignposter`,
  // are zero-cost when no profiler is attached (`OSSignposter`), and are pure
  // measurement — production behaviour is unchanged.

  /// `DataReader.fetchEntrySections` start → return. The ATTRIBUTION signal:
  /// how long the article-list read itself takes, measured on the reader
  /// actor. Windowing this against `writePersistPage` (below) isolates the
  /// under-burst read cost from the at-rest baseline.
  static let readFetchSections: StaticString = "read-fetch-sections"
  /// `EntryListView` structural reload: structural key change → sections
  /// replaced (a user-visible "different list" load). The PERCEPTION +
  /// OCCUPANCY signal — how long panel-2 shows its blank window, and how
  /// much of that time overlaps an active write-persist.
  static let structuralReload: StaticString = "structural-reload"
  /// One sync-page network GET (`Tnet`): `FeedbinClient.fetchEntries` for a
  /// single page. The gap this interval represents is what an unbounded
  /// prefetch stream buffers away, collapsing the persist cadence.
  static let netFetchPage: StaticString = "net-fetch-page"
  /// One sync-page persist (`Tpersist`): `DataWriter.persistEntries` for a
  /// single page. Back-to-back `writePersistPage` intervals with no
  /// `netFetchPage` gap between them are the coordinator-saturation signature.
  static let writePersistPage: StaticString = "write-persist-page"
}
