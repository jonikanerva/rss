import AppKit

/// Geometry of one article-list row (issue #170): the line budget of the
/// text column, the spacing and padding constants `EntryRowView` lays out
/// with, the fixed text-column height and the row-height floor derived from
/// them.
///
/// Pure and `nonisolated`: no view state, no side effects. The file is a
/// member of BOTH the app target and `FeederUITests`, so the UI test that
/// pins the row pitch computes its expectation from the same source the app
/// renders with (`STACK.md § 13`, DRY) instead of a copied constant.
nonisolated enum EntryRowMetrics {
  // MARK: - Fonts

  /// Base point sizes of the three row fonts. `AppFontSettings` builds its
  /// `rowTitle` / `rowFeedName` / `rowSummary` aliases from these, and
  /// `lineHeights(scale:)` reads the matching `NSFont` metrics, so the
  /// column height and the floor can never drift from the fonts the row
  /// renders with.
  static let titleBaseSize: CGFloat = 13
  static let metaBaseSize: CGFloat = 12
  static let summaryBaseSize: CGFloat = 12

  /// Whole-point line heights of the three row fonts at one text-size
  /// scale: `ceil(ascender - descender + leading)` each. This is the
  /// arithmetic the column and the floor are built from, not a promise
  /// about layout: SwiftUI's laid-out line pitch differs from these values
  /// by up to 1 pt per slot in either direction (measured on macOS 27).
  /// `EntryRowGeometryTests` (T1) pins the measured sum against the column.
  nonisolated struct LineHeights: Equatable, Sendable {
    let title: CGFloat
    let meta: CGFloat
    let summary: CGFloat
  }

  // MARK: - Layout constants

  /// Line budget of the text column: `titleLineLimit` title lines, the
  /// `domainLineLimit` domain line and `excerptColumnLines` summary lines.
  /// The column's height is FIXED at that budget (`textColumnHeight`), so
  /// the row is the same height for every content shape. Inside the column
  /// the title takes one or two lines, the domain always takes its reserved
  /// line, and the summary fills the rest: `excerptColumnLines` lines under
  /// a two-line title, one more under a one-line title.
  static let titleLineLimit = 2
  static let domainLineLimit = 1
  static let excerptColumnLines = 2
  /// Text of the domain line when the row has no domain (`nil` or an empty
  /// string). A single space, not an empty string: SwiftUI lays an EMPTY
  /// `Text` with reserved space out 14 pt tall at every font size
  /// (measured), while a space takes the font's own line height, so the
  /// space left for the summary is the same with and without a domain.
  /// Invisible; the row sets its own accessibility label, so VoiceOver
  /// never reads it.
  static let reservedDomainPlaceholder = " "
  /// Render-time line limit of the summary: the column budget plus every
  /// title line a short title leaves free. Precondition for the extra line
  /// to fit: the title line height is at least the summary line height at
  /// every text size (`EntryRowMetricsTests` pins it), so one unused title
  /// line always holds one summary line.
  static let excerptLineLimit = excerptColumnLines + titleLineLimit - 1
  /// Vertical gap between the title block, the domain line and the excerpt.
  static let textSpacing: CGFloat = 3
  /// `.padding(.vertical, _)` around the whole row content. Carries the
  /// whole vertical rhythm between rows: the `List` row insets are set to
  /// zero vertically (`listRowInsets`), so the row height the table sees is
  /// exactly this content height and the floor equals it by construction
  /// instead of by a measured inset constant. 12 = the previous 4 plus the
  /// 8 the default inset added above and below.
  static let verticalPadding: CGFloat = 12
  /// Explicit horizontal `listRowInsets`. The macOS `.inset` list style's
  /// default, read from the row frames on macOS 27 (17 pt each side), pinned
  /// so the row geometry does not move when the vertical inset becomes zero.
  static let horizontalInset: CGFloat = 17
  static let faviconSize: CGFloat = 24
  static let faviconTopPadding: CGFloat = 2
  /// Horizontal gap between the favicon column and the text column.
  static let faviconSpacing: CGFloat = 15
  /// Horizontal gap between the title and the time label on the title row.
  static let titleTimeSpacing: CGFloat = 5
  /// Head-room between the row's natural height and the floor. With the
  /// text column fixed, the natural height is `textColumnHeight` plus the
  /// vertical padding exactly, for every content shape. The margin guards
  /// against a sub-point rounding difference between the bridge's normal
  /// and fallback row heights: a hypothesis, not a measurement. Without it
  /// floor == natural, and a 1-pt split between the two modes could not be
  /// ruled out. `EntryRowGeometryTests` pins `floor - natural ==
  /// rowHeightMargin` for every row shape.
  static let rowHeightMargin: CGFloat = 2

  // MARK: - Derivation

  /// Fixed height of the text column from the three line heights: two title
  /// lines + gap + one domain line + gap + two summary lines. Pure
  /// arithmetic, unit-tested without rendering.
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

  /// Line heights of the row fonts at a text-size `scale`
  /// (`AppTextSize.scaleFactor`). Each is the font's own metrics,
  /// `ascender - descender + leading`, rounded UP to a whole point
  /// (`NSLayoutManager.defaultLineHeight(for:)` was rejected: its docs say
  /// the value varies with typesetter behaviour). `Font.system(size:weight:)`
  /// resolves to the same `NSFont.systemFont`. Weight does not change the
  /// metrics: semibold and regular report identical values at every scale.
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
