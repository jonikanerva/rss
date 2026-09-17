import Foundation

/// Stores the widths of the two leading `NavigationSplitView` columns — the
/// sidebar and the content column (article list) — across launches (issue
/// #170). Feeder owns these widths because on macOS 27 the split-view
/// bridge's own autosave restores the content frame as `width − x` (see
/// `SplitViewAutosaveReset`); the stored value is handed to the split view
/// as the launch `ideal`, the only width preference the bridge honours.
///
/// No width bounds. Owner decision (2026-09-17, binding): the app must not
/// limit how people lay out their screen. The stored value is applied as
/// `ideal` only; the platform divider and the column content's own minimum
/// size are the only limits.
///
/// Single-setting pattern (`OpenAIModelSetting`), not an `@Observable` owner:
/// the widths have no in-session reader. `ColumnWidthRecorder` writes them
/// when a divider drag settles; `ContentView` reads them once when the view
/// is created. A live binding would hand the split view a new preferred
/// width in the middle of a drag and make the divider fight the drag.
///
/// Window-layout preferences like the text size, not user data. Never
/// transmitted. Reads and writes one `UserDefaults` key per column.
nonisolated enum ColumnWidthSetting {
  /// The two persisted columns. The raw value is the `UserDefaults` key; the
  /// content key predates the sidebar one and is unchanged, so a value
  /// stored by an earlier build survives.
  nonisolated enum Column: String, CaseIterable, Sendable {
    case sidebar = "sidebar_column_width"
    case content = "content_column_width"

    var userDefaultsKey: String { rawValue }

    /// Launch width when nothing usable is stored: fresh install, reset, or a
    /// corrupt value. Content 400 = the width the owner drags the column to;
    /// sidebar 238 = the sidebar width measured in the owner's launch log, so
    /// a user who never drags sees today's layout.
    var defaultIdealWidth: CGFloat {
      switch self {
      case .sidebar: 238
      case .content: 400
      }
    }
  }

  /// Storage guard, NOT a layout rule: a measured width below this is a
  /// collapsed or hidden column (a hidden sidebar measures 0), never a width
  /// a person chose, so it is not stored and not restored. The user may drag
  /// a column narrower than this if the platform allows it; the value simply
  /// will not persist.
  static let sanityFloor: CGFloat = 100

  /// Result of one `persist` call. Feeds the settled-width log line and the
  /// unit tests; pure decision table, no side effect in the enum itself.
  nonisolated enum PersistOutcome: Equatable, Sendable {
    /// Below `sanityFloor`: a collapsed or hidden column.
    case skippedBelowSanityFloor
    /// Equal to the value `restoredIdealWidth` already returns. On a healthy
    /// launch this is the outcome of the first settled value: the platform
    /// laid the column out at our own `ideal`.
    case skippedEqualToStored
    /// The first settled value after launch differed from our `ideal`: the
    /// platform laid out something else. Never stored; in the log this is
    /// the alarm that the launch layout is not ours.
    case skippedLaunchLayout
    /// Written to the store, in whole points.
    case stored(CGFloat)
  }

  /// The launch `ideal` for `column`: the stored width, or the column's
  /// default when the key is absent or holds no usable number.
  /// `double(forKey:)` returns 0 for an absent key or a wrong type; 0,
  /// negative, NaN, infinite and below-floor values all fall back to the
  /// default. No clamp. Production callers read `UserDefaults.standard`;
  /// tests pass an isolated suite.
  static func restoredIdealWidth(for column: Column, in defaults: UserDefaults = .standard) -> CGFloat {
    let stored = defaults.double(forKey: column.userDefaultsKey)
    guard stored.isFinite, stored >= Double(sanityFloor) else { return column.defaultIdealWidth }
    return CGFloat(stored)
  }

  /// Record a settled column width, in whole points, rounded DOWN.
  ///
  /// Round-down is load-bearing: on a Retina display the divider sits on
  /// half points, so schoolbook rounding of `ideal + 0.5` would store
  /// `ideal + 1` and drift the column one point per launch. Rounding down
  /// maps `ideal + 0.5` back to `ideal`.
  ///
  /// Check ORDER: sanity floor, then equal-to-stored, then launch layout,
  /// then store. A healthy launch therefore logs `skippedEqualToStored`
  /// (the platform applied our `ideal`), and `skippedLaunchLayout` appears
  /// only when the platform laid out something else — the log outcome is
  /// the health signal. The first settled value is never stored either way.
  @discardableResult
  static func persist(
    _ width: CGFloat, for column: Column, isLaunchLayout: Bool, in defaults: UserDefaults = .standard
  ) -> PersistOutcome {
    guard width.isFinite else { return .skippedBelowSanityFloor }
    let rounded = width.rounded(.down)
    guard rounded >= sanityFloor else { return .skippedBelowSanityFloor }
    guard rounded != restoredIdealWidth(for: column, in: defaults) else { return .skippedEqualToStored }
    if isLaunchLayout { return .skippedLaunchLayout }
    defaults.set(Double(rounded), forKey: column.userDefaultsKey)
    return .stored(rounded)
  }
}
