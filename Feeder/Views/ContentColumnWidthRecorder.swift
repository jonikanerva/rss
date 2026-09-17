import SwiftUI
import os

/// One geometry sample of the content column: its width and its leading edge
/// in window coordinates (about the sidebar width plus the divider), so one
/// event gives both columns for the diagnostic log.
nonisolated struct ColumnGeometry: Equatable, Sendable {
  let width: CGFloat
  let originX: CGFloat
}

/// Records the content column's settled width (issue #170). Applied ONCE, on
/// the content-column `ZStack` in `ContentView`, which keeps a single identity
/// across the launch branch swap (empty state → list): the "first settled
/// value" below is then the platform's launch layout for the whole launch.
/// Never applied per row.
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
  /// launch layout, not a choice. Flipped after the first settled value
  /// regardless of its outcome.
  @State
  private var hasSeenLaunchLayout = false
  /// Reference instant for the "ms since launch" log field; pinned to the
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
        // Diagnostic for issue #170 — remove before merge. One line per
        // launch: the very first raw geometry, before any settle.
        if geometry == nil {
          ContentColumnWidthDiagnostics.logger.notice(
            "first geometry width=\(sample.width, privacy: .public) x=\(sample.originX, privacy: .public) t=\(elapsedMilliseconds(), privacy: .public)ms"
          )
        }
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
