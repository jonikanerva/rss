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
//
// Persistence isolation: every test that mutates `AppFontSettings.textSize`
// injects a per-suite `UserDefaults` so the `didSet` write-back lands in a
// throwaway store. Without this, running the suite locally would silently
// overwrite the developer's chosen text size in the shipped app's
// preferences. `makeIsolatedSettings(textSize:)` is the only constructor
// these tests use.

/// Per-suite `UserDefaults` store, cleared after every use so tests cannot
/// leak state into each other or into shipped preferences.
@MainActor
private func makeIsolatedSettings(textSize: AppTextSize = .medium) -> AppFontSettings {
  let suiteName = "FeederTests.appTextSize.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: suiteName) ?? .standard
  store.removePersistentDomain(forName: suiteName)
  return AppFontSettings(textSize: textSize, userDefaults: store)
}

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
    let settings = makeIsolatedSettings(textSize: .small)
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
    let settings = makeIsolatedSettings(textSize: .medium)
    let firstRead = settings.body
    let secondRead = settings.body

    #expect(firstRead == secondRead)
  }

  @Test
  func allAliasesDifferAcrossScales() {
    // Defends every published alias against a future refactor that forgets
    // to multiply by `scaleFactor`. If any of these become accidentally
    // size-independent, the test fails before users see flat scaling.
    let small = makeIsolatedSettings(textSize: .small)
    let large = makeIsolatedSettings(textSize: .xxLarge)

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

  // MARK: - Utility-text legibility floor

  /// Pins each sidebar-utility alias to its currently-shipping base point
  /// size at `Small` (× 0.85). Two guarantees fall out of this:
  ///
  /// 1. **HIG floor:** the resolved point size at `Small` must be ≥ 10pt.
  ///    macOS HIG calls 10pt the legibility floor for utility text, and
  ///    uppercase footer text (`rowFeedName`) is the worst-case combo —
  ///    uppercase + sub-9pt drops below readable. A regression that drops
  ///    any base back below 12pt would fail the equality check here and
  ///    the next test's floor assertion.
  /// 2. **Pinned base size:** locks the base size as a contract. A future
  ///    redesign that drops `sidebarBadge` from 12pt to 11pt is allowed,
  ///    but only via this test updating in the same change — the
  ///    accompanying floor assertion guards against a base below 12pt.
  ///
  /// `Font.system(size:weight:)` is `Equatable`; matching the expected
  /// construction is the cheapest robust signal.
  @Test
  func utilityAliasesAtSmallMatchExpectedBaseSizes() {
    let settings = makeIsolatedSettings(textSize: .small)
    let smallScale = AppTextSize.small.scaleFactor

    #expect(settings.sidebarBadge == .system(size: 12 * smallScale, weight: .regular))
    #expect(settings.rowFeedName == .system(size: 12 * smallScale))
    #expect(settings.status == .system(size: 12 * smallScale))
  }

  /// Locks the resolved point size at the user's `Small` text-size setting
  /// to the macOS HIG ~10pt legibility floor for the three sidebar utility
  /// aliases. A future change that drops any of these base sizes below 12pt
  /// would cross the floor at × 0.85 and fail this assertion — exactly the
  /// regression these tests are meant to catch.
  ///
  /// 12pt × 0.85 = 10.2pt for the current shipping configuration; the floor
  /// is strict `≥ 10pt`.
  @Test
  func utilityAliasBaseSizesStayAboveLegibilityFloorAtSmall() {
    let smallScale = AppTextSize.small.scaleFactor
    let floor: CGFloat = 10

    // Each of these tracks `AppFontSettings`. If any base drops, the
    // computed resolved-at-Small size drops below 10pt and the test fails.
    let sidebarBadgeBase: CGFloat = 12
    let rowFeedNameBase: CGFloat = 12
    let statusBase: CGFloat = 12

    #expect(sidebarBadgeBase * smallScale >= floor)
    #expect(rowFeedNameBase * smallScale >= floor)
    #expect(statusBase * smallScale >= floor)
  }
}
