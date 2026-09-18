import AppKit

/// Geometry of one article-list row: the text column's line budget, the spacing
/// and padding `EntryRowView` lays out with, and the fixed column height and
/// row-height floor derived from them.
///
/// Pure and `nonisolated`. The file belongs to both the app target and the UI
/// test target, so the test that pins the row pitch computes its expectation
/// from the same source the app renders with (`STACK.md § 13`).
nonisolated enum EntryRowMetrics {
  // MARK: - Fonts

  /// Base point sizes of the three row fonts. `AppFontSettings` builds its row
  /// aliases from these and `lineHeights(scale:)` reads the matching `NSFont`
  /// metrics, so the column height cannot drift from the rendered fonts.
  static let titleBaseSize: CGFloat = 13
  static let metaBaseSize: CGFloat = 12
  static let summaryBaseSize: CGFloat = 12

  /// Whole-point line heights of the three row fonts at one text-size scale.
  /// This is the arithmetic the column and the floor are built from, not a
  /// promise about layout: SwiftUI's laid-out line pitch can differ per slot.
  /// `EntryRowGeometryTests` checks the rendered sum against the column.
  nonisolated struct LineHeights: Equatable, Sendable {
    let title: CGFloat
    let meta: CGFloat
    let summary: CGFloat
  }

  // MARK: - Layout constants

  /// Line budget of the text column: the title lines, the domain line, and the
  /// summary lines. The column height is fixed at that budget, so the row is
  /// the same height for every content shape. The title takes one or two lines,
  /// the domain always takes its reserved line, and the summary fills the rest.
  static let titleLineLimit = 2
  static let domainLineLimit = 1
  static let excerptColumnLines = 2
  /// Text of the domain line when the row has no domain. It must be a space,
  /// not an empty string: SwiftUI lays an empty `Text` out at a fixed height at
  /// every font size, while a space takes the font's own line height, so the
  /// summary gets the same space either way. The row sets its own accessibility
  /// label, so VoiceOver never reads it.
  static let reservedDomainPlaceholder = " "
  /// Render-time line limit of the summary: the column budget plus every title
  /// line a short title leaves free. The extra line fits only because the title
  /// line height is at least the summary line height at every text size, which
  /// `EntryRowMetricsTests` pins.
  static let excerptLineLimit = excerptColumnLines + titleLineLimit - 1
  /// Vertical gap between the title block, the domain line and the excerpt.
  static let textSpacing: CGFloat = 3
  /// Vertical padding around the row content. It carries the whole vertical
  /// rhythm between rows, because the `List` row insets are zero vertically, so
  /// the height the table sees is exactly this content height.
  static let verticalPadding: CGFloat = 12
  /// Explicit horizontal `listRowInsets`, matching the `.inset` list style's
  /// own default. Pinned, so the row geometry does not move when the vertical
  /// inset becomes zero.
  static let horizontalInset: CGFloat = 17
  static let faviconSize: CGFloat = 24
  static let faviconTopPadding: CGFloat = 2
  /// Horizontal gap between the favicon column and the text column.
  static let faviconSpacing: CGFloat = 15
  /// Horizontal gap between the title and the time label on the title row.
  static let titleTimeSpacing: CGFloat = 5
  /// Head-room between the row's natural height and the list's row-height
  /// floor, which keeps the floor at or above the rendered height.
  static let rowHeightMargin: CGFloat = 2

  // MARK: - Derivation

  /// Fixed height of the text column from the three line heights and the gaps
  /// between them. Pure arithmetic, testable without rendering.
  static func textColumnHeight(
    titleLineHeight: CGFloat, metaLineHeight: CGFloat, summaryLineHeight: CGFloat
  ) -> CGFloat {
    CGFloat(titleLineLimit) * titleLineHeight
      + textSpacing
      + CGFloat(domainLineLimit) * metaLineHeight
      + textSpacing
      + CGFloat(excerptColumnLines) * summaryLineHeight
  }

  /// Natural height of a row from the three line heights: the text column
  /// or the favicon column, whichever is taller, plus the vertical padding
  /// and the margin.
  static func rowHeight(
    titleLineHeight: CGFloat, metaLineHeight: CGFloat, summaryLineHeight: CGFloat
  ) -> CGFloat {
    let textColumn = textColumnHeight(
      titleLineHeight: titleLineHeight, metaLineHeight: metaLineHeight, summaryLineHeight: summaryLineHeight)
    let faviconColumn = faviconTopPadding + faviconSize
    return max(textColumn, faviconColumn) + 2 * verticalPadding + rowHeightMargin
  }

  /// Line heights of the row fonts at a text-size scale, each rounded up to a
  /// whole point. `Font.system(size:weight:)` resolves to the same `NSFont`, so
  /// the arithmetic matches what SwiftUI renders.
  static func lineHeights(scale: CGFloat) -> LineHeights {
    func lineHeight(_ baseSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
      let font = NSFont.systemFont(ofSize: baseSize * scale, weight: weight)
      return ceil(font.ascender - font.descender + font.leading)
    }
    return LineHeights(
      title: lineHeight(titleBaseSize, weight: .semibold),
      meta: lineHeight(metaBaseSize, weight: .regular),
      summary: lineHeight(summaryBaseSize, weight: .regular)
    )
  }

  /// Fixed text-column height at a text-size `scale`.
  static func textColumnHeight(scale: CGFloat) -> CGFloat {
    let heights = lineHeights(scale: scale)
    return textColumnHeight(
      titleLineHeight: heights.title, metaLineHeight: heights.meta, summaryLineHeight: heights.summary)
  }

  /// Row-height floor at a text-size `scale`.
  static func rowHeightFloor(scale: CGFloat) -> CGFloat {
    let heights = lineHeights(scale: scale)
    return rowHeight(
      titleLineHeight: heights.title, metaLineHeight: heights.meta, summaryLineHeight: heights.summary)
  }
}
