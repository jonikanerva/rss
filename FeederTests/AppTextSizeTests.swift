import SwiftUI
import Testing

@testable import Feeder

// Silent-regression guard for the user-facing AppTextSize enum and the
// AppFontSettings observable that owns it: locks the rawValue → scaleFactor
// mapping, the `1`-based numbering that exists specifically to keep the
// `UserDefaults` zero-fallback from clobbering the `.medium` default, and
// verifies that `AppFontSettings` actually produces a different font at
// different sizes — the property that `.dynamicTypeSize(_:)` failed to
// provide on macOS and that motivated the explicit scale factor.

@MainActor
struct AppTextSizeTests {
  // MARK: - Scale factor mapping

  @Test
  func smallScaleFactorIsBelowOne() {
    #expect(AppTextSize.small.scaleFactor == 0.85)
  }

  @Test
  func mediumScaleFactorIsOne() {
    #expect(AppTextSize.medium.scaleFactor == 1.0)
  }

  @Test
  func largeScaleFactorIsAboveOne() {
    #expect(AppTextSize.large.scaleFactor == 1.15)
  }

  @Test
  func xLargeScaleFactorIs1Point3() {
    #expect(AppTextSize.xLarge.scaleFactor == 1.3)
  }

  @Test
  func xxLargeScaleFactorIs1Point5() {
    #expect(AppTextSize.xxLarge.scaleFactor == 1.5)
  }

  @Test
  func scaleFactorIsStrictlyMonotonic() {
    let factors = AppTextSize.allCases.map(\.scaleFactor)
    let sorted = factors.sorted()
    #expect(factors == sorted)
    #expect(Set(factors).count == factors.count)
  }

  // MARK: - Enum hygiene

  @Test
  func allCasesCountIsFive() {
    #expect(AppTextSize.allCases.count == 5)
  }

  @Test
  func rawValueZeroIsNil() {
    // Documents the zero-trap escape: a missing UserDefaults integer reads
    // back as 0, so AppTextSize(rawValue: 0) must not collide with the first
    // case — otherwise the default of .medium would be silently overridden
    // on a fresh install.
    #expect(AppTextSize(rawValue: 0) == nil)
  }

  @Test
  func rawValueOneIsSmall() {
    #expect(AppTextSize(rawValue: 1) == .small)
  }

  // MARK: - AppFontSettings integration

  @Test
  func bodyFontDiffersAcrossScales() {
    // The whole point of the explicit scale: `AppFontSettings.body` must
    // produce visibly different fonts at different `textSize` values.
    // `Font` is `Equatable`, so an inequality assertion is the cheapest
    // robust signal that the alias re-evaluates against the current scale.
    let settings = AppFontSettings()
    settings.textSize = .small
    let smallBody = settings.body
    settings.textSize = .xxLarge
    let xxLargeBody = settings.body

    #expect(smallBody != xxLargeBody)
  }

  @Test
  func bodyFontAtMediumIsStable() {
    // Two reads at the same scale must produce the same `Font` — guards
    // against accidental nondeterminism (e.g. a future change pulling in
    // a time-dependent factor).
    let settings = AppFontSettings()
    settings.textSize = .medium
    let firstRead = settings.body
    let secondRead = settings.body

    #expect(firstRead == secondRead)
  }

  @Test
  func allAliasesDifferAcrossScales() {
    // Defends every published alias against a future refactor that forgets
    // to multiply by `scaleFactor`. If any of these become accidentally
    // size-independent, the test fails before users see flat scaling.
    let small = AppFontSettings()
    small.textSize = .small
    let large = AppFontSettings()
    large.textSize = .xxLarge

    #expect(small.articleTitle != large.articleTitle)
    #expect(small.sectionHeader != large.sectionHeader)
    #expect(small.subsectionHeader != large.subsectionHeader)
    #expect(small.minorHeader != large.minorHeader)
    #expect(small.minorInlineHeading != large.minorInlineHeading)
    #expect(small.body != large.body)
    #expect(small.codeBlock != large.codeBlock)
    #expect(small.rowTitle != large.rowTitle)
    #expect(small.rowSummary != large.rowSummary)
    #expect(small.rowFeedName != large.rowFeedName)
    #expect(small.headline != large.headline)
    #expect(small.caption != large.caption)
    #expect(small.bodyMedium != large.bodyMedium)
    #expect(small.metadata != large.metadata)
    #expect(small.status != large.status)
    #expect(small.sectionLabel != large.sectionLabel)
  }
}
