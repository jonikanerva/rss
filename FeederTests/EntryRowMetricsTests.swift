import Foundation
import Testing

@testable import Feeder

/// Pins the article-row height floor (issue #170): the pure arithmetic in
/// `EntryRowMetrics.rowHeight`, the floor derivation `rowHeightFloor(scale:)`,
/// the stored `AppFontSettings.entryRowHeight` at every text size, and the
/// recompute on a text-size change.
@Suite("Entry row metrics")
struct EntryRowMetricsTests {
  private static let suiteName = "EntryRowMetricsTests"

  @MainActor
  private func makeSettings(_ size: AppTextSize) -> AppFontSettings {
    let defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
    defaults.removePersistentDomain(forName: Self.suiteName)
    return AppFontSettings(textSize: size, userDefaults: defaults)
  }

  // MARK: - rowHeight arithmetic

  @Test("rowHeight sums two title lines, one meta line, two summary lines, gaps, padding and margin")
  func rowHeightArithmetic() {
    let height = EntryRowMetrics.rowHeight(
      titleLineHeight: 16, metaLineHeight: 15, summaryLineHeight: 15)
    let expected: CGFloat =
      2 * 16 + EntryRowMetrics.textSpacing + 15 + EntryRowMetrics.textSpacing + 2 * 15
      + 2 * EntryRowMetrics.verticalPadding + EntryRowMetrics.rowHeightMargin
    #expect(height == expected)
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

  // MARK: - entryRowHeight per text size

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

  // MARK: - Recompute on change

  @Test("entryRowHeight recomputes when textSize changes and stays put otherwise")
  @MainActor
  func entryRowHeightRecomputes() {
    let settings = makeSettings(.medium)
    let medium = settings.entryRowHeight
    settings.textSize = .xxLarge
    let huge = settings.entryRowHeight
    #expect(huge > medium)
    #expect(huge == makeSettings(.xxLarge).entryRowHeight)
    settings.textSize = .xxLarge
    #expect(settings.entryRowHeight == huge)
    settings.textSize = .medium
    #expect(settings.entryRowHeight == medium)
  }
}
