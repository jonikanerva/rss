import SwiftUI

// MARK: - Centralized Font Theme

/// All UI fonts derive from `baseSize`. Adjust it to scale the entire app.
/// Sizes that share the same numeric value still keep distinct names so the
/// call site documents its intent and future changes can split them apart
/// without touching every caller.
enum FontTheme {
  /// The root size from which all other sizes are computed.
  static let baseSize: CGFloat = 15

  // MARK: - Offsets from baseSize

  static let statusSize: CGFloat = baseSize - 2  // 13
  static let captionSize: CGFloat = baseSize - 1  // 14
  static let bodySize: CGFloat = baseSize + 3  // 18
  static let rowTitleSize: CGFloat = baseSize + 2  // 17 — article list row title
  static let sectionHeaderSize: CGFloat = baseSize + 7  // 22
  static let articleTitleSize: CGFloat = baseSize + 15  // 30
  static let iconSize: CGFloat = baseSize + 35  // 50

  // MARK: - Semantic aliases
  // Same numeric value as an existing size, different role at the call site.
  // Kept as aliases so we can redesign a specific surface without having to
  // grep through every place the raw number appears.

  static let metadataSize: CGFloat = baseSize  // 15
  static let rowSummarySize: CGFloat = baseSize  // 15 — summary excerpt in row
  static let rowFeedNameSize: CGFloat = statusSize  // 13 — uppercase feed name
  static let pillSize: CGFloat = captionSize  // 14

  // MARK: - Semantic font styles

  static var headline: Font { .system(size: baseSize, weight: .bold) }
  static var title: Font { .system(size: articleTitleSize, weight: .bold) }
  static var caption: Font { .system(size: captionSize) }
  static var bodyMedium: Font { .system(size: baseSize, weight: .medium) }

  // MARK: - Colors

  static let domainPillColor = Color(nsColor: .secondaryLabelColor)
}
