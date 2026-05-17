import SwiftUI

// MARK: - FontTheme (color-only namespace)

/// Thin namespace for visual constants that have no dependency on the user's
/// text-size choice. Font aliases moved to `AppFontSettings` (an `@Observable`
/// type read via `@Environment`) so that picker changes notify only the
/// surfaces that render text, without tearing down `ContentView`'s `@State`
/// (sidebar selection, article selection, scroll position).
enum FontTheme {
  /// Color used for the inline domain text under a row title.
  static let domainPillColor = Color(nsColor: .secondaryLabelColor)
}
