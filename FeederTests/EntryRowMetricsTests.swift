import Foundation
import Testing

@testable import Feeder

/// Pins the article-row geometry: the pure arithmetic in
/// `EntryRowMetrics.textColumnHeight` and `rowHeight`, the line-height
/// derivation and its precondition for the title / summary split, the
/// stored `AppFontSettings.entryRowHeight` and `entryRowTextColumnHeight`
/// at every text size, and the recompute on a text-size change.
@Suite("Entry row metrics")
struct EntryRowMetricsTests {
  private static let suiteName = "EntryRowMetricsTests"

  /// Fixed text-column height per text size: 2 title lines + 3 + 1 domain
  /// line + 3 + 2 summary lines, from the `NSFont` line heights
  /// (14/13/13, 16/15/15, 18/17/17, 20/19/19, 23/22/22).
  private static let textColumnHeights: [AppTextSize: CGFloat] = [
    .small: 73, .medium: 83, .large: 93, .xLarge: 103, .xxLarge: 118,
  ]

  @MainActor
  private func makeSettings(_ size: AppTextSize) -> AppFontSettings {
    let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
    defaults.removePersistentDomain(forName: Self.suiteName)
    return AppFontSettings(textSize: size, userDefaults: defaults)
  }

  // MARK: - Arithmetic

  @Test("textColumnHeight sums two title lines, one meta line, two summary lines and the gaps")
  func textColumnHeightArithmetic() {
    let height = EntryRowMetrics.textColumnHeight(
      titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    let expected: CGFloat = 2 * 16 + EntryRowMetrics.textSpacing + 15 + EntryRowMetrics.textSpacing + 2 * 15
    #expect(height == expected)
  }

  @Test("rowHeight is the text column plus padding and margin")
  func rowHeightArithmetic() {
    let height = EntryRowMetrics.rowHeight(
      titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    let textColumn = EntryRowMetrics.textColumnHeight(
      titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    #expect(height == textColumn + 2 * EntryRowMetrics.verticalPadding + EntryRowMetrics.rowHeightMargin)
  }

  @Test("rowHeight never drops below the favicon column")
  func rowHeightFaviconFloor() {
    let height = EntryRowMetrics.rowHeight(titleLineHeight: 1, metaLineHeight: 1, summaryLineHeight: 1)
    let faviconColumn = EntryRowMetrics.faviconTopPadding + EntryRowMetrics.faviconSize
    #expect(height == faviconColumn + 2 * EntryRowMetrics.verticalPadding + EntryRowMetrics.rowHeightMargin)
  }

  @Test("rowHeight grows with every line height")
  func rowHeightMonotonic() {
    let base = EntryRowMetrics.rowHeight(titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    #expect(EntryRowMetrics.rowHeight(titleLineHeight: 17, metaLineHeight: 15, summaryLineHeight: 15) > base)
    #expect(EntryRowMetrics.rowHeight(titleLineHeight: 16, metaLineHeight: 16, summaryLineHeight: 15) > base)
    #expect(EntryRowMetrics.rowHeight(titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 16) > base)
  }

  // MARK: - Line budget

  @Test("the summary render limit is the column budget plus the free title line")
  func excerptLineLimit() {
    #expect(EntryRowMetrics.excerptColumnLines == 2)
    #expect(EntryRowMetrics.titleLineLimit == 2)
    #expect(EntryRowMetrics.excerptLineLimit == 3)
    #expect(
      EntryRowMetrics.excerptLineLimit
        == EntryRowMetrics.excerptColumnLines + EntryRowMetrics.titleLineLimit - 1)
  }

  @Test(
    "the title line height is at least the summary line height, so a free title line holds a summary line",
    arguments: AppTextSize.allCases)
  @MainActor
  func titleLineHoldsSummaryLine(size: AppTextSize) {
    let heights = EntryRowMetrics.lineHeights(scale: size.scaleFactor)
    #expect(heights.title >= heights.summary, "\(size): \(heights)")
    #expect(heights.title == heights.title.rounded(), "whole points only")
    #expect(heights.meta == heights.meta.rounded(), "whole points only")
    #expect(heights.summary == heights.summary.rounded(), "whole points only")
  }

  @Test("textColumnHeight per text size", arguments: AppTextSize.allCases)
  @MainActor
  func textColumnHeightPerSize(size: AppTextSize) throws {
    let expected = try #require(Self.textColumnHeights[size])
    #expect(EntryRowMetrics.textColumnHeight(scale: size.scaleFactor) == expected)
  }

  @Test("the floor is the text column plus padding and margin at every text size", arguments: AppTextSize.allCases)
  @MainActor
  func floorFromTextColumn(size: AppTextSize) {
    let scale = size.scaleFactor
    #expect(
      EntryRowMetrics.rowHeightFloor(scale: scale)
        == EntryRowMetrics.textColumnHeight(scale: scale) + 2 * EntryRowMetrics.verticalPadding
        + EntryRowMetrics.rowHeightMargin)
  }

  // MARK: - Stored heights per text size

  @Test("entryRowHeight is above the 34-point content minimum at every text size", arguments: AppTextSize.allCases)
  @MainActor
  func entryRowHeightAboveMinimum(size: AppTextSize) {
    let settings = makeSettings(size)
    #expect(settings.entryRowHeight > 34)
    #expect(settings.entryRowHeight == settings.entryRowHeight.rounded(), "whole points only")
  }

  @Test("entryRowHeight is strictly monotonic in text size")
  @MainActor
  func entryRowHeightMonotonic() {
    let heights = AppTextSize.allCases.map { makeSettings($0).entryRowHeight }
    for (smaller, larger) in zip(heights, heights.dropFirst()) {
      #expect(smaller < larger, "\(heights)")
    }
  }

  @Test("entryRowHeight at medium matches the default-size row: 2x13pt + 12pt + 2x12pt lines")
  @MainActor
  func entryRowHeightMediumShape() {
    let settings = makeSettings(.medium)
    // 13 pt and 12 pt system fonts: ascender - descender + leading rounds up to 16 pt and 15 pt.
    let expected = EntryRowMetrics.rowHeight(titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    #expect(settings.entryRowHeight == expected)
  }

  @Test("entryRowHeight equals EntryRowMetrics.rowHeightFloor for the same scale", arguments: AppTextSize.allCases)
  @MainActor
  func entryRowHeightMatchesFloorDerivation(size: AppTextSize) {
    #expect(makeSettings(size).entryRowHeight == EntryRowMetrics.rowHeightFloor(scale: size.scaleFactor))
  }

  @Test("entryRowTextColumnHeight equals the pinned column height for the same scale", arguments: AppTextSize.allCases)
  @MainActor
  func entryRowTextColumnHeightPerSize(size: AppTextSize) throws {
    let settings = makeSettings(size)
    #expect(settings.entryRowTextColumnHeight == EntryRowMetrics.textColumnHeight(scale: size.scaleFactor))
    #expect(settings.entryRowTextColumnHeight == (try #require(Self.textColumnHeights[size])))
    #expect(
      settings.entryRowHeight
        == settings.entryRowTextColumnHeight + 2 * EntryRowMetrics.verticalPadding + EntryRowMetrics.rowHeightMargin)
  }

  // MARK: - Recompute on change

  @Test("both stored heights recompute when textSize changes and stay put otherwise")
  @MainActor
  func storedHeightsRecompute() {
    let settings = makeSettings(.medium)
    let medium = (settings.entryRowHeight, settings.entryRowTextColumnHeight)
    settings.textSize = .xxLarge
    let huge = (settings.entryRowHeight, settings.entryRowTextColumnHeight)
    #expect(huge.0 > medium.0)
    #expect(huge.1 > medium.1)
    let fresh = makeSettings(.xxLarge)
    #expect(huge == (fresh.entryRowHeight, fresh.entryRowTextColumnHeight))
    settings.textSize = .xxLarge
    #expect((settings.entryRowHeight, settings.entryRowTextColumnHeight) == huge)
    settings.textSize = .medium
    #expect((settings.entryRowHeight, settings.entryRowTextColumnHeight) == medium)
  }
}
