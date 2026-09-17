import SwiftUI
import os

/// One geometry sample of the content column: its width and its leading edge
/// in window coordinates (about the sidebar width plus the divider), so one
/// settled log line gives both the width and where the column sits.
nonisolated struct ColumnGeometry: Equatable, Sendable {
  let width: CGFloat
  let originX: CGFloat
}

/// Records the content column's settled width (issue #170). Applied ONCE,
/// through `persistedColumnWidth(ideal:)`, on the content-column `ZStack` in
/// `ContentView`, which keeps a single identity across the launch branch
/// swap (empty state → list), so "the first settled value" below is the
/// platform's launch layout for the whole launch. Never applied per row.
///
/// Shape: one geometry observer feeds a private `@State`; a `.task(id:)`
/// debounce waits for the width to stop changing and then hands it to
/// `ContentColumnWidthSetting.persist` once (`EntryListView.navDebounce` is
/// the same shape). Per-frame cost during a divider drag is one `@State`
/// write inside this modifier plus one task cancel and spawn — a few
/// microseconds, accepted against the 8.3 ms frame budget (`STACK.md § 4`).
/// The `UserDefaults` write happens at human-event frequency, once per
/// settled drag (`STACK.md § 14` envelope). No `Timer`, no GCD. No per-frame
/// logging.
struct ContentColumnWidthRecorder: ViewModifier {
  /// Store for the width. Production uses `.standard`; tests inject a suite.
  let defaults: UserDefaults
  @State
  private var geometry: ColumnGeometry?
  /// The first settled value after this identity appears is the platform's
  /// launch layout, not a choice, and is never stored. Flipped after the
  /// first settled value regardless of its outcome.
  ///
  /// KEEP even though a healthy launch makes it redundant (the first settled
  /// value then equals our `ideal` and is equal-skipped anyway): it is the
  /// ONLY guard against AppKit's mis-restored autosave frame. On macOS 27 the
  /// bridge autosaves the content frame with `x` = the sidebar width and can
  /// restore the column as `width − x` (issue #170, Feedback tracked in
  /// #190). Feeder no longer removes those autosave keys: a visible `ideal`
  /// beats the restore (owner gate on commits A and M). If a future build
  /// lets the restore win again, without this skip the recorder would store
  /// `width − sidebar` as intent at every launch and shrink the stored width
  /// by the sidebar width per launch (593 → 355 → 117 → floor). With the
  /// skip the store stays intact and the settled log line shows
  /// `skippedLaunchLayout` — the alarm.
  @State
  private var hasSeenLaunchLayout = false
  /// Reference instant for the "ms since appear" log field; pinned to the
  /// identity like the other state.
  @State
  private var createdAt: ContinuousClock.Instant = .now

  /// How long the width must stay unchanged before it is stored: twice the
  /// navigation debounce. A divider pauses this long only when the drag has
  /// settled. A quit inside this window loses only that drag; the previous
  /// value stays.
  private static let settleDelay: Duration = .milliseconds(300)

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: ColumnGeometry.self) { proxy in
        ColumnGeometry(width: proxy.size.width, originX: proxy.frame(in: .global).minX)
      } action: { sample in
        geometry = sample
      }
      // Every geometry change cancels the pending sleep and starts a new one,
      // so the store sees one value per settled layout.
      .task(id: geometry) {
        guard let geometry else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }
        let isLaunchLayout = !hasSeenLaunchLayout
        hasSeenLaunchLayout = true
        let outcome = ContentColumnWidthSetting.persist(
          geometry.width, isLaunchLayout: isLaunchLayout, in: defaults)
        // D4: every settled measurement and its decision. Numbers and Bools
        // only (`STACK.md § 8`).
        ContentColumnWidthDiagnostics.logger.notice(
          "settled width=\(geometry.width, privacy: .public) x=\(geometry.originX, privacy: .public) t=\(elapsedMilliseconds(), privacy: .public)ms launch=\(isLaunchLayout, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
      }
  }

  private func elapsedMilliseconds() -> Int {
    Int((ContinuousClock.now - createdAt) / .milliseconds(1))
  }
}

extension View {
  /// Persist and restore the content column's width (issue #170): the
  /// `ContentColumnWidthRecorder` INSIDE, the width preference
  /// `navigationSplitViewColumnWidth(ideal:)` OUTERMOST. Apply this to the
  /// content of the column as its last modifier; the order is load-bearing.
  ///
  /// MEASURED constraint, UNDOCUMENTED by Apple (headless spike, 2026-09-17):
  /// an `onGeometryChange` placed outside `navigationSplitViewColumnWidth`
  /// hides the width preference from the split view, and the column lays out
  /// at the platform default (recorder outside → 200 pt; recorder inside →
  /// the 500-pt `ideal`). No Apple document describes how the preference
  /// reaches the split view; the closest anchor is the modifier's own
  /// guidance, "Apply this modifier to the content of a column".
  /// `PersistedColumnWidthTests` pins the order with a positive and a
  /// negative case, and `STACK.md § 7` bans the loose pair of modifiers.
  func persistedColumnWidth(ideal: CGFloat, defaults: UserDefaults = .standard) -> some View {
    modifier(ContentColumnWidthRecorder(defaults: defaults))
      .navigationSplitViewColumnWidth(ideal: ideal)
  }
}
