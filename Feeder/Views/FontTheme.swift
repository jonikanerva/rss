import SwiftUI

// MARK: - FontTheme (color-only namespace)

/// Namespace for the visual constants that do not depend on the user's
/// text-size choice. Every font alias lives on `AppFontSettings` instead, so a
/// size change notifies only the surfaces that render text.
enum FontTheme {
  /// Color used for the inline domain text under a row title.
  static let domainPillColor = Color(nsColor: .secondaryLabelColor)
}
