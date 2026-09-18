import SwiftUI

/// `UserDefaults` key holding the user's app-wide text size. `AppFontSettings`
/// is its single writer. It lives at module scope so a test can clear the key
/// by name without reaching into the type.
nonisolated let appTextSizeUserDefaultsKey = "app_text_size"

/// User-selectable, app-wide text size. `AppFontSettings` owns the active value
/// and multiplies every font alias's base point size by `scaleFactor`. That
/// multiplication is the only mechanism that scales SwiftUI text on macOS:
/// `.dynamicTypeSize(_:)` and `@ScaledMetric` propagate the environment value
/// without re-resolving the system fonts.
///
/// The raw values start at 1, so a missing `UserDefaults` integer — which reads
/// back as 0 — cannot resolve to a valid case and the caller's fallback wins.
enum AppTextSize: Int, CaseIterable, Identifiable, Sendable {
  case small = 1
  case medium  // 2
  case large  // 3
  case xLarge  // 4
  case xxLarge  // 5

  var id: Int { rawValue }

  /// Multiplier applied to every `AppFontSettings` alias, and to `--app-scale`
  /// in the reader CSS. Centred on 1.0 at `.medium`, so the default selection
  /// keeps the app's visual mass.
  var scaleFactor: CGFloat {
    switch self {
    case .small: 0.85
    case .medium: 1.0
    case .large: 1.15
    case .xLarge: 1.3
    case .xxLarge: 1.5
    }
  }

  /// Sentence case, with no trailing punctuation, like the rest of Settings.
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
