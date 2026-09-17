import Foundation
import Testing

@testable import Feeder

/// Pins the content-column width setting (issue #170): the launch `ideal`
/// read from `UserDefaults`, its fallback and clamping, and the write rules
/// of `persist` (whole points, out-of-range skipped, equal value skipped).
/// Every test uses its own `UserDefaults` suite, so nothing leaks into the
/// developer's app preferences or between tests.
@Suite("Content column width setting")
struct ContentColumnWidthSettingTests {
  private static func makeSuite(_ name: String) throws -> UserDefaults {
    let suiteName = "ContentColumnWidthSettingTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private static func stored(_ defaults: UserDefaults) -> Double? {
    defaults.object(forKey: ContentColumnWidthSetting.userDefaultsKey) as? Double
  }

  // MARK: - Bounds

  @Test("the bounds match the split-view contract: 320 minimum, 400 default, 600 maximum")
  func bounds() {
    #expect(ContentColumnWidthSetting.minimumWidth == 320)
    #expect(ContentColumnWidthSetting.defaultIdealWidth == 400)
    #expect(ContentColumnWidthSetting.maximumWidth == 600)
    #expect(ContentColumnWidthSetting.userDefaultsKey == "content_column_width")
  }

  // MARK: - restoredIdealWidth

  @Test("an absent key restores the default")
  func absentKeyRestoresDefault() throws {
    let defaults = try Self.makeSuite("absent")
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: defaults) == 400)
  }

  @Test("a stored width below the minimum restores the minimum")
  func clampsLow() throws {
    let defaults = try Self.makeSuite("clampLow")
    defaults.set(100.0, forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: defaults) == 320)
  }

  @Test("a stored width above the maximum restores the maximum")
  func clampsHigh() throws {
    let defaults = try Self.makeSuite("clampHigh")
    defaults.set(900.0, forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: defaults) == 600)
  }

  @Test("zero, a negative value, NaN and a wrong type restore the default")
  func unusableValuesRestoreDefault() throws {
    let zero = try Self.makeSuite("zero")
    zero.set(0.0, forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: zero) == 400)

    let negative = try Self.makeSuite("negative")
    negative.set(-450.0, forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: negative) == 400)

    // A NaN may be rejected by the store or read back as NaN; both paths
    // must end at the default.
    let nan = try Self.makeSuite("nan")
    nan.set(Double.nan, forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: nan) == 400)

    let text = try Self.makeSuite("text")
    text.set("wide", forKey: ContentColumnWidthSetting.userDefaultsKey)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: text) == 400)
  }

  // MARK: - persist

  @Test("an in-range width round-trips")
  func roundTrip() throws {
    let defaults = try Self.makeSuite("roundTrip")
    ContentColumnWidthSetting.persist(450, in: defaults)
    #expect(Self.stored(defaults) == 450)
    #expect(ContentColumnWidthSetting.restoredIdealWidth(in: defaults) == 450)
  }

  @Test("widths are stored in whole points")
  func roundsToWholePoints() throws {
    let defaults = try Self.makeSuite("rounding")
    ContentColumnWidthSetting.persist(449.6, in: defaults)
    #expect(Self.stored(defaults) == 450)
    ContentColumnWidthSetting.persist(350.4, in: defaults)
    #expect(Self.stored(defaults) == 350)
  }

  @Test("an out-of-range width never overwrites the stored value")
  func outOfRangeIsSkipped() throws {
    let defaults = try Self.makeSuite("outOfRange")
    ContentColumnWidthSetting.persist(450, in: defaults)
    ContentColumnWidthSetting.persist(250, in: defaults)
    #expect(Self.stored(defaults) == 450)
    ContentColumnWidthSetting.persist(700, in: defaults)
    #expect(Self.stored(defaults) == 450)
    ContentColumnWidthSetting.persist(.nan, in: defaults)
    #expect(Self.stored(defaults) == 450)
    ContentColumnWidthSetting.persist(.infinity, in: defaults)
    #expect(Self.stored(defaults) == 450)
  }

  @Test("the bounds themselves are stored; one point outside is not")
  func boundsAreInclusive() throws {
    let defaults = try Self.makeSuite("inclusive")
    ContentColumnWidthSetting.persist(320, in: defaults)
    #expect(Self.stored(defaults) == 320)
    ContentColumnWidthSetting.persist(600, in: defaults)
    #expect(Self.stored(defaults) == 600)
    ContentColumnWidthSetting.persist(601, in: defaults)
    #expect(Self.stored(defaults) == 600)
    ContentColumnWidthSetting.persist(319, in: defaults)
    #expect(Self.stored(defaults) == 600)
  }

  @Test("a width equal to the restored value writes nothing")
  func equalValueIsSkipped() throws {
    // Fresh install at the default width: the key stays absent.
    let fresh = try Self.makeSuite("equalDefault")
    ContentColumnWidthSetting.persist(400, in: fresh)
    #expect(Self.stored(fresh) == nil)
    ContentColumnWidthSetting.persist(400.3, in: fresh)
    #expect(Self.stored(fresh) == nil)

    // A stored value re-reported after launch stays as stored.
    let stored = try Self.makeSuite("equalStored")
    ContentColumnWidthSetting.persist(450, in: stored)
    ContentColumnWidthSetting.persist(450, in: stored)
    #expect(Self.stored(stored) == 450)
    // A different in-range value still lands.
    ContentColumnWidthSetting.persist(350, in: stored)
    #expect(Self.stored(stored) == 350)
  }
}
