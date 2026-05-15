import SwiftUI

/// UserDefaults key under which the user's selected app-wide text size is
/// stored. Lives at module scope (matches the convention from
/// `Feeder/Helpers/CredentialSaving.swift`) so both `FeederApp` and
/// `SettingsView` can bind `@AppStorage` to the same key without a string
/// literal duplication.
nonisolated let appTextSizeUserDefaultsKey = "app_text_size"

/// User-selectable, app-wide text size. Drives `.dynamicTypeSize(_:)` applied
/// at the scene-content level in `FeederApp`, so every SwiftUI surface that
/// renders with semantic text styles (`.body`, `.headline`, etc.) scales
/// uniformly with the chosen size.
///
/// **macOS behaviour note:** the system-level Dynamic Type slider (Accessibility →
/// Display → Larger Text) is iOS-only — on macOS the user-facing path to scale
/// system text styles is this per-app picker, applied through the
/// `.dynamicTypeSize(_:)` view modifier (public, `macOS 12.0+`).
///
/// **Why raw values start at 1 (not 0):** a missing `UserDefaults` integer
/// reads back as `0`, which would otherwise collide with the first case and
/// silently override the `.medium` `@AppStorage` default. Starting at `1`
/// makes `AppTextSize(rawValue: 0) == nil`, so the `@AppStorage` default wins
/// on a fresh install / cleared preferences.
enum AppTextSize: Int, CaseIterable, Identifiable, Sendable {
  case small = 1
  case medium  // 2
  case large  // 3
  case xLarge  // 4
  case xxLarge  // 5

  var id: Int { rawValue }

  /// The Dynamic Type bucket applied to the SwiftUI environment via
  /// `.dynamicTypeSize(_:)`. Five options chosen to match the visible scale
  /// steps `.small` through `.xxLarge` — accessibility sizes (`.accessibility1`+)
  /// are deliberately excluded to keep macOS layouts intact (sidebar /
  /// settings frames are sized for the standard range).
  var dynamicTypeSize: DynamicTypeSize {
    switch self {
    case .small: .small
    case .medium: .medium
    case .large: .large
    case .xLarge: .xLarge
    case .xxLarge: .xxLarge
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
