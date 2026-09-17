import Foundation
import Testing

@testable import Feeder

/// Pins the content-column width setting (issue #170): the launch `ideal`
/// read from `UserDefaults` with its fallback and NO clamp, and the decision
/// table of `persist` (launch layout skipped, sanity floor, equal skipped,
/// whole points rounded down, no upper bound). Every test uses its own
/// `UserDefaults` suite, so nothing leaks into the developer's app
/// preferences or between tests.
@Suite("Content column width setting")
struct ContentColumnWidthSettingTests {
  private typealias Setting = ContentColumnWidthSetting

  private static func makeSuite(_ name: String) throws -> UserDefaults {
    let suiteName = "ContentColumnWidthSettingTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private static func stored(_ defaults: UserDefaults) -> Double? {
    defaults.object(forKey: Setting.userDefaultsKey) as? Double
  }

  // MARK: - Constants

  @Test("400 default, 100 sanity floor, no bounds")
  func constants() {
    #expect(Setting.defaultIdealWidth == 400)
    #expect(Setting.sanityFloor == 100)
    #expect(Setting.userDefaultsKey == "content_column_width")
  }

  // MARK: - restoredIdealWidth

  @Test("an absent key restores the default")
  func absentKeyRestoresDefault() throws {
    let defaults = try Self.makeSuite("absent")
    #expect(Setting.restoredIdealWidth(in: defaults) == 400)
  }

  @Test("a stored width is restored without a clamp: 900 stays 900, 150 stays 150")
  func noClamp() throws {
    let wide = try Self.makeSuite("wide")
    wide.set(900.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: wide) == 900)

    let narrow = try Self.makeSuite("narrow")
    narrow.set(150.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: narrow) == 150)
  }

  @Test("a stored width below the sanity floor restores the default")
  func belowSanityFloorRestoresDefault() throws {
    let defaults = try Self.makeSuite("belowFloor")
    defaults.set(50.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 400)
    defaults.set(99.9, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 400)
    defaults.set(100.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 100)
  }

  @Test("zero, a negative value, NaN and a wrong type restore the default")
  func unusableValuesRestoreDefault() throws {
    let zero = try Self.makeSuite("zero")
    zero.set(0.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: zero) == 400)

    let negative = try Self.makeSuite("negative")
    negative.set(-450.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: negative) == 400)

    // A NaN may be rejected by the store or read back as NaN; both paths
    // must end at the default.
    let nan = try Self.makeSuite("nan")
    nan.set(Double.nan, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: nan) == 400)

    let text = try Self.makeSuite("text")
    text.set("wide", forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: text) == 400)
  }

  // MARK: - persist outcomes

  @Test("the launch layout is never stored, whatever its value")
  func launchLayoutIsSkipped() throws {
    let defaults = try Self.makeSuite("launch")
    #expect(Setting.persist(450, isLaunchLayout: true, in: defaults) == .skippedLaunchLayout)
    #expect(Setting.persist(200, isLaunchLayout: true, in: defaults) == .skippedLaunchLayout)
    #expect(Setting.persist(50, isLaunchLayout: true, in: defaults) == .skippedLaunchLayout)
    #expect(Self.stored(defaults) == nil)
    // The launch skip also holds when a value is already stored.
    Setting.persist(450, isLaunchLayout: false, in: defaults)
    #expect(Setting.persist(520, isLaunchLayout: true, in: defaults) == .skippedLaunchLayout)
    #expect(Self.stored(defaults) == 450)
  }

  @Test("a width below the sanity floor, NaN or infinity is skipped")
  func belowSanityFloorIsSkipped() throws {
    let defaults = try Self.makeSuite("floor")
    Setting.persist(450, isLaunchLayout: false, in: defaults)
    #expect(Setting.persist(80, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Setting.persist(99.9, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Setting.persist(0, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Setting.persist(.nan, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Setting.persist(.infinity, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Self.stored(defaults) == 450)
  }

  @Test("a width equal to the restored value is skipped")
  func equalValueIsSkipped() throws {
    // Fresh install at the default width: the key stays absent.
    let fresh = try Self.makeSuite("equalDefault")
    #expect(Setting.persist(400, isLaunchLayout: false, in: fresh) == .skippedEqualToStored)
    #expect(Setting.persist(400.7, isLaunchLayout: false, in: fresh) == .skippedEqualToStored)
    #expect(Self.stored(fresh) == nil)

    // A stored value re-reported later stays as stored.
    let stored = try Self.makeSuite("equalStored")
    #expect(Setting.persist(450, isLaunchLayout: false, in: stored) == .stored(450))
    #expect(Setting.persist(450, isLaunchLayout: false, in: stored) == .skippedEqualToStored)
    #expect(Setting.persist(450.5, isLaunchLayout: false, in: stored) == .skippedEqualToStored)
    #expect(Self.stored(stored) == 450)
  }

  @Test("an in-range width is stored and round-trips")
  func storedRoundTrips() throws {
    let defaults = try Self.makeSuite("roundTrip")
    #expect(Setting.persist(450, isLaunchLayout: false, in: defaults) == .stored(450))
    #expect(Self.stored(defaults) == 450)
    #expect(Setting.restoredIdealWidth(in: defaults) == 450)
    #expect(Setting.persist(350, isLaunchLayout: false, in: defaults) == .stored(350))
    #expect(Setting.restoredIdealWidth(in: defaults) == 350)
  }

  @Test("there is no upper bound: 900 and 1200 are stored")
  func noUpperBound() throws {
    let defaults = try Self.makeSuite("noUpperBound")
    #expect(Setting.persist(900, isLaunchLayout: false, in: defaults) == .stored(900))
    #expect(Self.stored(defaults) == 900)
    #expect(Setting.persist(1200, isLaunchLayout: false, in: defaults) == .stored(1200))
    #expect(Setting.restoredIdealWidth(in: defaults) == 1200)
  }

  @Test("widths are stored in whole points, rounded down: 450.5 → 450, 600.5 → 600")
  func roundsDown() throws {
    let defaults = try Self.makeSuite("roundDown")
    #expect(Setting.persist(450.5, isLaunchLayout: false, in: defaults) == .stored(450))
    #expect(Self.stored(defaults) == 450)
    #expect(Setting.persist(600.5, isLaunchLayout: false, in: defaults) == .stored(600))
    #expect(Self.stored(defaults) == 600)
    #expect(Setting.persist(519.9, isLaunchLayout: false, in: defaults) == .stored(519))
    #expect(Self.stored(defaults) == 519)
  }

  @Test("the sanity floor is inclusive: 100 is stored, 99.9 is not")
  func sanityFloorIsInclusive() throws {
    let defaults = try Self.makeSuite("floorInclusive")
    #expect(Setting.persist(100, isLaunchLayout: false, in: defaults) == .stored(100))
    #expect(Self.stored(defaults) == 100)
    #expect(Setting.persist(99.9, isLaunchLayout: false, in: defaults) == .skippedBelowSanityFloor)
    #expect(Self.stored(defaults) == 100)
  }
}
