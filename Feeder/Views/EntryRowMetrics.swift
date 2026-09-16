import AppKit

/// Geometry of one article-list row (issue #170): the line counts every
/// text slot reserves, the spacing and padding constants `EntryRowView`
/// lays out with, and the row-height floor derived from them.
///
/// Pure and `nonisolated`: no view state, no side effects. The file is a
/// member of BOTH the app target and `FeederUITests`, so the UI test that
/// pins the row pitch computes its expectation from the same source the app
/// renders with (`STACK.md § 13`, DRY) instead of a copied constant.
nonisolated enum EntryRowMetrics {
  // MARK: - Fonts

  /// Base point sizes of the three row fonts. `AppFontSettings` builds its
  /// `rowTitle` / `rowFeedName` / `rowSummary` aliases from these, and
  /// `rowHeightFloor(scale:)` reads the matching `NSFont` metrics, so the
  /// floor can never drift from the fonts the row renders with.
  static let titleBaseSize: CGFloat = 13
  static let metaBaseSize: CGFloat = 12
  static let summaryBaseSize: CGFloat = 12

  // MARK: - Layout constants

  /// Every text slot is ALWAYS present and reserves its full line count, so
  /// a row's natural height is the same for a one-line title, a missing
  /// domain, or an empty excerpt.
  static let titleLineLimit = 2
  static let domainLineLimit = 1
  static let excerptLineLimit = 2
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
  /// Head-room above the summed line heights. SwiftUI lays a reserved text
  /// slot out at most a whole point taller than the rounded-up font line
  /// height; the margin keeps the floor at or above the rendered height so
  /// the floor wins for every row. `EntryRowGeometryTests` measures the
  /// fullest row headlessly at every text size and pins the slack to
  /// 0...6 pt, so the margin can neither fall short nor drift high.
  static let rowHeightMargin: CGFloat = 2

  // MARK: - Derivation

  /// Natural height of a full row from the three line heights: the text
  /// column (2 title lines + gap + 1 domain line + gap + 2 excerpt lines) or
  /// the favicon column, whichever is taller, plus the vertical padding and
  /// the margin. Pure arithmetic, unit-tested without rendering.
  static func rowHeight(
    titleLineHeight: CGFloat, metaLineHeight: CGFloat, summaryLineHeight: CGFloat
  ) -> CGFloat {
    let textColumn =
      CGFloat(titleLineLimit) * titleLineHeight
      + textSpacing
      + CGFloat(domainLineLimit) * metaLineHeight
      + textSpacing
      + CGFloat(excerptLineLimit) * summaryLineHeight
    let faviconColumn = faviconTopPadding + faviconSize
    return max(textColumn, faviconColumn) + 2 * verticalPadding + rowHeightMargin
  }

  /// Row-height floor at a text-size `scale` (`AppTextSize.scaleFactor`).
  /// Each line height is the font's own metrics, `ascender - descender +
  /// leading`, rounded UP to a whole point — the line height SwiftUI's text
  /// layout uses on macOS (`NSLayoutManager.defaultLineHeight(for:)` was
  /// rejected: its docs say the value varies with typesetter behaviour).
  /// `Font.system(size:weight:)` resolves to the same `NSFont.systemFont`.
  static func rowHeightFloor(scale: CGFloat) -> CGFloat {
    func lineHeight(_ baseSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
      let font = NSFont.systemFont(ofSize: baseSize * scale, weight: weight)
      return ceil(font.ascender - font.descender + font.leading)
    }
    return rowHeight(
      titleLineHeight: lineHeight(titleBaseSize, weight: .semibold),
      metaLineHeight: lineHeight(metaBaseSize, weight: .regular),
      summaryLineHeight: lineHeight(summaryBaseSize, weight: .regular)
    )
  }
}
