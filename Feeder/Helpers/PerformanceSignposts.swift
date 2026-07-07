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
}
