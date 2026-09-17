import SwiftUI

/// Records the content column's settled width (issue #170). Applied ONCE, on
/// the content-column `Group` in `ContentView`: both branches of that group
/// fill the column, so the measured size is the column's width, not the
/// window's. Never applied per row.
///
/// Shape: one geometry observer feeds a private `@State`; a `.task(id:)`
/// debounce waits for the width to stop changing and then stores it once
/// (`EntryListView.navDebounce` is the same shape). Per-frame cost during a
/// divider drag is one `@State` write inside this modifier plus one task
/// cancel and spawn — a few microseconds and a few hundred bytes, accepted
/// against the 8.3 ms frame budget (`STACK.md § 4`). The `UserDefaults`
/// write happens at human-event frequency, once per settled drag, inside the
/// `STACK.md § 14` MainActor `UserDefaults` envelope. No `Timer`, no GCD.
/// The `@State` lives in this modifier, so a width change does not
/// re-evaluate the column's content.
struct ContentColumnWidthRecorder: ViewModifier {
  /// Store for the width. Production uses `.standard`; tests inject a suite.
  let defaults: UserDefaults
  @State
  private var measuredWidth: CGFloat?

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
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        measuredWidth = width
      }
      // Every width change cancels the pending sleep and starts a new one, so
      // the store sees one value per settled drag. `persist` skips values
      // outside the bounds and values equal to the stored one.
      .task(id: measuredWidth) {
        guard let measuredWidth else { return }
        try? await Task.sleep(for: Self.settleDelay)
        guard !Task.isCancelled else { return }
        ContentColumnWidthSetting.persist(measuredWidth, in: defaults)
      }
  }
}
