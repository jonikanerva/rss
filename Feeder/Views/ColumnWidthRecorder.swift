import SwiftUI
import os

/// One geometry sample of a split-view column: its width and its leading edge
/// in window coordinates, so one settled log line gives both the width and
/// where the column sits.
nonisolated struct ColumnGeometry: Equatable, Sendable {
  let width: CGFloat
  let originX: CGFloat
}

/// Records a split-view column's settled width. Applied ONCE per column
/// through `persistedColumnWidth(column:ideal:)`: on `sidebarView` (stable
/// identity) and on the content-column `ZStack`, which keeps a single
/// identity across the launch branch swap (empty state → list), so "the first
/// settled value" below is the platform's launch layout for the whole launch.
/// Never applied per row.
///
/// Shape: one geometry observer feeds a private `@State`; a `.task(id:)`
/// debounce keyed on the WIDTH ONLY waits for the width to stop changing and
/// then hands it to `ColumnWidthSetting.persist` once. The leading edge `x`
/// is logged but never re-arms the debounce: a sidebar drag moves the
/// content column without changing its width, and the debounce must not
/// treat that as a settled content-width change. Per-frame cost during a
/// divider drag is one `@State` write inside this modifier and one task
/// cancel and spawn only when the width changed — a few microseconds,
/// accepted against the 8.3 ms frame budget (`STACK.md § 4`). The
/// `UserDefaults` write happens at human-event frequency, once per settled
/// drag (`STACK.md § 14` envelope). No `Timer`, no GCD. No per-frame logging.
struct ColumnWidthRecorder: ViewModifier {
  let column: ColumnWidthSetting.Column
  /// Store for the width. Production uses `.standard`; tests inject a suite.
  let defaults: UserDefaults
  @State
  private var geometry: ColumnGeometry?
  /// The first settled value after this identity appears is the platform's
  /// launch layout, not a choice, and is never stored. Flipped after the
  /// first settled value regardless of its outcome.
  ///
  /// This is the other half of the fail-safe behind `SplitViewAutosaveReset`:
  /// without this skip, a mis-restored autosave frame would be stored as
  /// intent at every launch. With the skip the store stays intact and the
  /// settled log line shows `skippedLaunchLayout` as the alarm.
  ///
  /// Accepted cost: a drag that starts before the first settled value
  /// (within `settleDelay` of the column appearing) is treated as the launch
  /// layout and is not stored; the next drag stores.
  @State
  private var hasSeenLaunchLayout = false
  /// Reference instant for the "ms since appear" log field; pinned to the
  /// identity like the other state.
  @State
  private var createdAt: ContinuousClock.Instant = .now

  /// How long the width must stay unchanged before it is stored. A divider
  /// pauses this long only when the drag has settled. A drag released less
  /// than `settleDelay` before quit keeps the previous width.
  private static let settleDelay: Duration = .milliseconds(150)

  init(column: ColumnWidthSetting.Column, defaults: UserDefaults = .standard) {
    self.column = column
    self.defaults = defaults
  }

  func body(content: Content) -> some View {
    content
      .onGeometryChange(for: ColumnGeometry.self) { proxy in
        ColumnGeometry(width: proxy.size.width, originX: proxy.frame(in: .global).minX)
      } action: { sample in
        geometry = sample
      }
      // Keyed on the WIDTH only: a change of `x` alone (a sidebar drag) must
      // not re-arm the debounce. Every width change cancels the pending
      // sleep and starts a new one, so the store sees one value per settled
      // layout.
      .task(id: geometry?.width) {
        guard let geometry else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }
        let isLaunchLayout = !hasSeenLaunchLayout
        hasSeenLaunchLayout = true
        if isLaunchLayout {
          let ideal = ColumnWidthSetting.restoredIdealWidth(for: column, in: defaults)
          if abs(geometry.width - ideal) > 1 {
            ColumnWidthDiagnostics.logLaunchMismatch(measured: geometry.width, ideal: ideal, for: column)
          }
        }
        let outcome = ColumnWidthSetting.persist(
          geometry.width, for: column, isLaunchLayout: isLaunchLayout, in: defaults)
        // Every settled measurement and its decision. Numbers, Bools and the
        // column key only (`STACK.md § 8`).
        ColumnWidthDiagnostics.logger.notice(
          "settled column=\(column.rawValue, privacy: .public) width=\(geometry.width, privacy: .public) x=\(geometry.originX, privacy: .public) t=\(elapsedMilliseconds(), privacy: .public)ms launch=\(isLaunchLayout, privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
      }
  }

  private func elapsedMilliseconds() -> Int {
    Int((ContinuousClock.now - createdAt) / .milliseconds(1))
  }
}

extension View {
  /// Persist and restore a `NavigationSplitView` column's width: the
  /// `ColumnWidthRecorder` for `column` INSIDE, the width preference
  /// `navigationSplitViewColumnWidth(ideal:)` OUTERMOST. Apply this to the
  /// content of a column as its last modifier; the order is load-bearing —
  /// a modifier outside the preference hides it from the split view, and the
  /// column lays out at the platform default instead of `ideal`.
  /// `PersistedColumnWidthTests` pins the order with a positive and a
  /// negative case, and `STACK.md § 7` bans the loose pair of modifiers.
  func persistedColumnWidth(
    column: ColumnWidthSetting.Column, ideal: CGFloat, defaults: UserDefaults = .standard
  ) -> some View {
    modifier(ColumnWidthRecorder(column: column, defaults: defaults))
      .navigationSplitViewColumnWidth(ideal: ideal)
  }
}
