import Foundation
import Testing

@testable import Feeder

/// Pins the content-column width setting (issue #170): the launch `ideal`
/// read from `UserDefaults` with its default and NO clamp, and the decision
/// table of `persist` in its check ORDER (sanity floor, equal-to-stored,
/// launch layout, store), whole points rounded down, no upper bound. Every
/// test uses its own `UserDefaults` suite, so nothing leaks into the
/// developer's app preferences or between tests.
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

  @Test("400 default, 100 sanity floor, one key, no bounds")
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
    let defaults = try Self.makeSuite("noClamp")
    defaults.set(900.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 900)
    defaults.set(150.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 150)
  }

  @Test("below the sanity floor, zero, negative, NaN and a wrong type restore the default")
  func unusableValuesRestoreDefault() throws {
    let defaults = try Self.makeSuite("unusable")
    for value in [50.0, 99.9, 0.0, -450.0] {
      defaults.set(value, forKey: Setting.userDefaultsKey)
      #expect(Setting.restoredIdealWidth(in: defaults) == 400, "\(value)")
    }
    // A NaN may be rejected by the store or read back as NaN; both paths end
    // at the default.
    defaults.set(Double.nan, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 400)
    defaults.set("wide", forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 400)
    defaults.set(100.0, forKey: Setting.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(in: defaults) == 100, "floor is inclusive")
  }

  // MARK: - persist: check order

  @Test("the sanity floor beats every other rule")
  func sanityFloorFirst() throws {
    let defaults = try Self.makeSuite("floor")
    Setting.persist(450, isLaunchLayout: false, in: defaults)
    for launch in [true, false] {
      #expect(Setting.persist(80, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(99.9, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(0, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(.nan, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(.infinity, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
    }
    #expect(Self.stored(defaults) == 450)
  }

  @Test("equal-to-stored beats the launch layout: a healthy launch logs skippedEqualToStored")
  func equalBeatsLaunch() throws {
    // Fresh install: the launch layout at the default width is "equal".
    let fresh = try Self.makeSuite("equalFresh")
    #expect(Setting.persist(400, isLaunchLayout: true, in: fresh) == .skippedEqualToStored)
    #expect(Setting.persist(400.5, isLaunchLayout: true, in: fresh) == .skippedEqualToStored)
    #expect(Self.stored(fresh) == nil)

    // Stored 586, platform lays out 586 at launch: equal, healthy.
    let stored = try Self.makeSuite("equalStored")
    Setting.persist(586, isLaunchLayout: false, in: stored)
    #expect(Setting.persist(586, isLaunchLayout: true, in: stored) == .skippedEqualToStored)
    #expect(Setting.persist(586.5, isLaunchLayout: true, in: stored) == .skippedEqualToStored)
    #expect(Setting.persist(586, isLaunchLayout: false, in: stored) == .skippedEqualToStored)
    #expect(Self.stored(stored) == 586)
  }

  @Test("the launch layout beats the store: a different first value is never written")
  func launchBeatsStore() throws {
    let fresh = try Self.makeSuite("launchFresh")
    #expect(Setting.persist(450, isLaunchLayout: true, in: fresh) == .skippedLaunchLayout)
    #expect(Setting.persist(200, isLaunchLayout: true, in: fresh) == .skippedLaunchLayout)
    #expect(Self.stored(fresh) == nil)

    // The mis-restored autosave case: stored 586, platform lays out 348.
    let stored = try Self.makeSuite("launchStored")
    Setting.persist(586, isLaunchLayout: false, in: stored)
    #expect(Setting.persist(348, isLaunchLayout: true, in: stored) == .skippedLaunchLayout)
    #expect(Self.stored(stored) == 586)
  }

  @Test("a settled non-launch width is stored, rounded down, with no upper bound")
  func storeRules() throws {
    let defaults = try Self.makeSuite("store")
    #expect(Setting.persist(450, isLaunchLayout: false, in: defaults) == .stored(450))
    #expect(Setting.restoredIdealWidth(in: defaults) == 450)
    #expect(Setting.persist(450.5, isLaunchLayout: false, in: defaults) == .skippedEqualToStored)
    #expect(Setting.persist(519.9, isLaunchLayout: false, in: defaults) == .stored(519))
    #expect(Setting.persist(600.5, isLaunchLayout: false, in: defaults) == .stored(600))
    #expect(Setting.persist(1200, isLaunchLayout: false, in: defaults) == .stored(1200))
    #expect(Setting.restoredIdealWidth(in: defaults) == 1200)
    #expect(Setting.persist(100, isLaunchLayout: false, in: defaults) == .stored(100))
    #expect(Self.stored(defaults) == 100)
  }
}
