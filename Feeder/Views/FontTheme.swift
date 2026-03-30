import SwiftUI

// MARK: - Centralized Font Theme

/// All UI fonts derive from `baseSize`. Adjust it to scale the entire app.
enum FontTheme {
  /// The root size from which all other sizes are computed.
  static let baseSize: CGFloat = 15  // was effectively 13

  // Relative sizes (offsets from baseSize)
  static let statusSize: CGFloat = baseSize - 2  // 13 (was 11)
  static let captionSize: CGFloat = baseSize - 1  // 14 (was 12)
  static let metadataSize: CGFloat = baseSize  // 15 (was 13)
  static let bodySize: CGFloat = baseSize + 3  // 18 (was 16)
  static let rowTitleSize: CGFloat = baseSize + 2  // 17 (was 15)
  static let sectionHeaderSize: CGFloat = baseSize + 7  // 22 (was 20)
  static let articleTitleSize: CGFloat = baseSize + 15  // 30 (was 26)
  static let pillSize: CGFloat = baseSize - 1  // 14 (was 12)
  static let iconSize: CGFloat = baseSize + 35  // 50 (was 48)

  // Replacements for semantic styles (private — use the Font properties below)
  private static let headlineSize: CGFloat = baseSize  // 15 (was .headline ~13)
  private static let titleSize: CGFloat = baseSize + 15  // 30 (was .title ~28)
  private static let bodyMediumSize: CGFloat = baseSize  // 15 (was .body ~13)

  // Font constructors for common semantic patterns
  static var headline: Font { .system(size: headlineSize, weight: .bold) }
  static var title: Font { .system(size: titleSize, weight: .bold) }
  static var caption: Font { .system(size: captionSize) }
  static var bodyMedium: Font { .system(size: bodyMediumSize, weight: .medium) }
}
