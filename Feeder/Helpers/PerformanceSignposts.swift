import os
import os.signpost

// MARK: - Shared OSSignposter

/// Shared `OSSignposter` for every `PerformanceSignpostName` signpost. The
/// category is `.pointsOfInterest`, so Instruments surfaces the signposts with
/// no extra configuration, and the subsystem matches the rest of the app
/// (`STACK.md § 8`).
///
/// `OSSignposter` does no work when no profiler is attached, so the calls need
/// no `#if DEBUG` gating. `nonisolated`, because the render path crosses
/// MainActor and a detached task.
nonisolated let perfSignposter = OSSignposter(
  subsystem: "com.feeder.app",
  category: .pointsOfInterest
)

// MARK: - Signpost names

/// Add or remove a name only together with its row in
/// `STACK.md § 4 → Signposts`. `nonisolated`, because callers cross MainActor
/// and nonisolated actor contexts interchangeably.
nonisolated enum PerformanceSignpostName {
  /// Sidebar selection commit → the article list's task fires. Measures the
  /// SwiftUI commit cost of a sidebar move.
  static let sidebarClick: StaticString = "sidebar-click"
  /// Article-row selection commit → the detail pane's task fires. Measures the
  /// SwiftUI commit cost of a row selection.
  static let articleClick: StaticString = "article-click"
  /// Render task start → the `renderedHTML` write, just before the web view
  /// loads it. Measures the off-MainActor render alone, without the
  /// click-to-task latency.
  static let detailRender: StaticString = "detail-render"

  // MARK: - Read-starvation instrumentation
  //
  // Four intervals that attribute one question: does a dense sync-page write
  // burst saturate the shared SwiftData coordinator and starve the article-list
  // read? The signposts do not change production behaviour.

  /// How long the article-list read takes on the reader actor. Windowed
  /// against `writePersistPage`, it separates the under-burst read cost from
  /// the at-rest baseline.
  static let readFetchSections: StaticString = "read-fetch-sections"
  /// End of the navigation debounce → sections replaced: how long the article
  /// list shows its blank window, and how much of that overlaps an active
  /// persist.
  static let structuralReload: StaticString = "structural-reload"
  /// One sync-page network GET. The gap it represents is what an unbounded
  /// prefetch stream buffers away, which collapses the persist cadence.
  static let netFetchPage: StaticString = "net-fetch-page"
  /// One sync-page persist. Back-to-back intervals with no `netFetchPage` gap
  /// between them are the coordinator-saturation signature.
  static let writePersistPage: StaticString = "write-persist-page"

  // MARK: - Structural-reload sub-cost split
  //
  // Finer signposts that split the non-fetch portion of `structuralReload`
  // across the individual MainActor operations.

  /// The row structural-equality walk on MainActor, which compares each row
  /// field by field.
  static let reloadDiff: StaticString = "reload-diff"
  /// The state assignment that marks the view dirty. The `List` render and
  /// layout that follow are the `structuralReload` residual once the named
  /// sub-intervals are subtracted.
  static let reloadStateAssign: StaticString = "reload-state-assign"
  /// The capture of the on-screen rows before a refresh assignment, and the
  /// compensating scroll after the table update. The end message holds the phase.
  static let scrollAnchor: StaticString = "scroll-anchor"
  /// Preference change → the next `ContentView` render pass. Isolates the
  /// whole-split-view re-evaluation one reload triggers.
  static let contentViewReeval: StaticString = "contentview-reeval"
  /// One row-body evaluation. Counting the events inside a `structuralReload`
  /// window shows whether the `List` rebuilds every row or only the visible
  /// ones.
  static let rowBodyBuild: StaticString = "row-body-build"
}
