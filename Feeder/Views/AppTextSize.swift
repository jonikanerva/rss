import SwiftUI

/// UserDefaults key under which the user's selected app-wide text size is
/// stored. Owned by `AppFontSettings` (single writer): its `init` reads the
/// key synchronously so the first frame uses the persisted value, and its
/// `textSize` `didSet` mirrors any change back to disk. Lives at module
/// scope (matches the convention from `Feeder/Helpers/CredentialSaving.swift`)
/// so test code can clear the key by name without reaching into the type.
nonisolated let appTextSizeUserDefaultsKey = "app_text_size"

/// User-selectable, app-wide text size. `AppFontSettings` owns the active
/// value and exposes `scaleFactor` through its private `scale` helper, which
/// multiplies every font alias's base point size by the chosen factor. This
/// is the only mechanism that actually scales SwiftUI text on macOS —
/// `.dynamicTypeSize(_:)` and `@ScaledMetric` were verified not to affect
/// rendered text size, despite propagating the environment value.
///
/// **Why this isn't `.dynamicTypeSize(_:)`:** on macOS the modifier sets the
/// environment value but SwiftUI's text-style rendering does not re-resolve
/// system fonts from it — `Font.body` etc. remain at their default sizes.
/// We therefore drive sizing explicitly via `Font.system(size:)` and apply a
/// scale multiplier here.
///
/// **Why raw values start at 1 (not 0):** a missing `UserDefaults` integer
/// reads back as `0`, which would otherwise collide with the first case.
/// Starting at `1` makes `AppTextSize(rawValue: 0) == nil`, so the
/// `?? .medium` fallback in `AppFontSettings.init()` resolves a missing /
/// invalid stored value to medium on a fresh install / cleared preferences.
enum AppTextSize: Int, CaseIterable, Identifiable, Sendable {
  case small = 1
  case medium  // 2
  case large  // 3
  case xLarge  // 4
  case xxLarge  // 5

  var id: Int { rawValue }

  /// Multiplier applied to every `AppFontSettings` alias's base point size
  /// (and to `--app-scale` in the WebView reader CSS). Centred on `1.0` for
  /// `.medium` so the default selection preserves the existing visual mass;
  /// the spread (0.85 → 1.5) is balanced between an acceptably small
  /// "compact" mode and a comfortable "huge" mode without breaking sidebar /
  /// settings frame budgets.
  var scaleFactor: CGFloat {
    switch self {
    case .small: 0.85
    case .medium: 1.0
    case .large: 1.15
    case .xLarge: 1.3
    case .xxLarge: 1.5
    }
  }

  /// Sentence case, no trailing punctuation — follows the rest of the
  /// Settings UI ("Sync Schedule", "Last sync", …).
  var displayName: LocalizedStringKey {
    switch self {
    case .small: "Small"
    case .medium: "Medium"
    case .large: "Large"
    case .xLarge: "Extra Large"
    case .xxLarge: "Huge"
    }
  }
}
