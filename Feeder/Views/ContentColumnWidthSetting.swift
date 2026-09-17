import Foundation

/// Stores the content-column (article list) width across launches (issue
/// #170). `NavigationSplitView` returns the column to its `ideal` width at
/// every launch, so Feeder records the width the user settles on and hands it
/// back as the launch `ideal`.
///
/// Single-setting pattern (`OpenAIModelSetting`), not an `@Observable` owner:
/// the width has no in-session reader. `ContentColumnWidthRecorder` writes it
/// when a divider drag settles; `ContentView` reads it once when the view is
/// created. A live binding would hand the split view a new preferred width
/// in the middle of a drag and make the divider fight the drag.
///
/// A window-layout preference like the text size, not user data. Never
/// transmitted.
nonisolated enum ContentColumnWidthSetting {
  /// Bounds of the content column. 320 keeps a two-line title plus the time
  /// column readable at the default text size; 600 keeps the detail pane
  /// above half the window at common window widths. HIG (macOS split views):
  /// "Set reasonable defaults for minimum and maximum pane sizes." Single
  /// source for `ContentView` and the unit tests; `EntryListLayoutUITests`
  /// copies the two bounds on purpose because the UI-test target does not
  /// import the app module.
  static let minimumWidth: CGFloat = 320
  /// Launch width when nothing usable is stored: fresh install, reset, or a
  /// corrupt value. Equals the owner's dragged width, so a reset is
  /// invisible for that layout.
  static let defaultIdealWidth: CGFloat = 400
  static let maximumWidth: CGFloat = 600
  static let userDefaultsKey = "content_column_width"

  /// The launch `ideal`: the stored width clamped to the bounds, or
  /// `defaultIdealWidth` when the key is absent or holds no usable number.
  /// `double(forKey:)` returns 0 for an absent key or a wrong type; 0,
  /// negative, NaN and infinite values all fall back to the default.
  /// Production callers read `UserDefaults.standard`; tests pass an isolated
  /// suite.
  static func restoredIdealWidth(in defaults: UserDefaults = .standard) -> CGFloat {
    let stored = defaults.double(forKey: userDefaultsKey)
    guard stored.isFinite, stored > 0 else { return defaultIdealWidth }
    return min(max(CGFloat(stored), minimumWidth), maximumWidth)
  }

  /// Record a settled column width, in whole points.
  ///
  /// Skips a width outside the bounds: a squeezed window or a transient
  /// layout must never overwrite a good value. Skips a width equal to the
  /// value `restoredIdealWidth` already returns, so the first geometry
  /// report after launch and a fresh install at the default width write
  /// nothing.
  static func persist(_ width: CGFloat, in defaults: UserDefaults = .standard) {
    guard width.isFinite else { return }
    let rounded = width.rounded()
    guard rounded >= minimumWidth, rounded <= maximumWidth else { return }
    guard rounded != restoredIdealWidth(in: defaults) else { return }
    defaults.set(Double(rounded), forKey: userDefaultsKey)
  }
}
