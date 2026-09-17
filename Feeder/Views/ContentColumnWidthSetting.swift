import Foundation

/// Stores the content-column (article list) width across launches (issue
/// #170). `NavigationSplitView` returns the column to its `ideal` width at
/// launch, so Feeder records the width the user settles on and hands it back
/// as the launch `ideal`.
///
/// No width bounds. Owner decision (2026-09-17, binding): the app must not
/// limit how people lay out their screen. The stored value is applied as
/// `ideal` only; the platform divider and the column content's own minimum
/// size are the only limits.
///
/// Single-setting pattern (`OpenAIModelSetting`), not an `@Observable` owner:
/// the width has no in-session reader. `ContentColumnWidthRecorder` writes it
/// when a divider drag settles; `ContentView` reads it once when the view is
/// created. A live binding would hand the split view a new preferred width
/// in the middle of a drag and make the divider fight the drag.
///
/// A window-layout preference like the text size, not user data. Never
/// transmitted. Reads and writes one `UserDefaults` key.
nonisolated enum ContentColumnWidthSetting {
  /// Launch width when nothing usable is stored: fresh install, reset, or a
  /// corrupt value. Equals the owner's dragged width, so a reset is
  /// invisible for that layout.
  static let defaultIdealWidth: CGFloat = 400
  /// Storage guard, NOT a layout rule: a measured width below this is a
  /// collapsed or hidden column, never a width a person chose, so it is not
  /// stored and not restored. The user may drag the column narrower than
  /// this if the platform allows it; the value simply will not persist.
  static let sanityFloor: CGFloat = 100
  static let userDefaultsKey = "content_column_width"

  /// Result of one `persist` call. Feeds the settled-width log line and the
  /// unit tests; pure decision table, no side effect in the enum itself.
  nonisolated enum PersistOutcome: Equatable, Sendable {
    /// The first settled value after launch is the platform's launch layout,
    /// not a choice; it is never stored.
    case skippedLaunchLayout
    /// Below `sanityFloor`: a collapsed or hidden column.
    case skippedBelowSanityFloor
    /// Equal to the value `restoredIdealWidth` already returns.
    case skippedEqualToStored
    /// Written to the store, in whole points.
    case stored(CGFloat)
  }

  /// The launch `ideal`: the stored width, or `defaultIdealWidth` when the
  /// key is absent or holds no usable number. `double(forKey:)` returns 0
  /// for an absent key or a wrong type; 0, negative, NaN, infinite and
  /// below-floor values all fall back to the default. No clamp: there is no
  /// upper bound, and the floor is a storage guard only. Production callers
  /// read `UserDefaults.standard`; tests pass an isolated suite.
  static func restoredIdealWidth(in defaults: UserDefaults = .standard) -> CGFloat {
    let stored = defaults.double(forKey: userDefaultsKey)
    guard stored.isFinite, stored >= Double(sanityFloor) else { return defaultIdealWidth }
    return CGFloat(stored)
  }

  /// Record a settled column width, in whole points, rounded DOWN.
  ///
  /// Round-down is load-bearing: on a Retina display the divider sits on
  /// half points, so schoolbook rounding of `ideal + 0.5` would store
  /// `ideal + 1` and drift the column one point per launch. Rounding down
  /// maps `ideal + 0.5` back to `ideal`.
  ///
  /// The first settled value after launch (`isLaunchLayout`) is the
  /// platform's launch layout, not a choice, and is never stored. Widths
  /// below `sanityFloor` are skipped. A width equal to the value
  /// `restoredIdealWidth` already returns is skipped, so a fresh install at
  /// the default width writes nothing.
  @discardableResult
  static func persist(
    _ width: CGFloat, isLaunchLayout: Bool, in defaults: UserDefaults = .standard
  ) -> PersistOutcome {
    if isLaunchLayout { return .skippedLaunchLayout }
    guard width.isFinite else { return .skippedBelowSanityFloor }
    let rounded = width.rounded(.down)
    guard rounded >= sanityFloor else { return .skippedBelowSanityFloor }
    guard rounded != restoredIdealWidth(in: defaults) else { return .skippedEqualToStored }
    defaults.set(Double(rounded), forKey: userDefaultsKey)
    return .stored(rounded)
  }
}
