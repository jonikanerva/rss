import Foundation
import Testing

@testable import Feeder

/// Pins the column width setting for both leading columns (issue #170): the
/// launch `ideal` read from `UserDefaults` with its per-column default and NO
/// clamp, and the decision table of `persist` in its check ORDER (sanity
/// floor, equal-to-stored, launch layout, store), whole points rounded down,
/// no upper bound. Every test uses its own `UserDefaults` suite, so nothing
/// leaks into the developer's app preferences or between tests.
@Suite("Column width setting")
struct ColumnWidthSettingTests {
  private typealias Setting = ColumnWidthSetting
  typealias Column = ColumnWidthSetting.Column

  private static func makeSuite(_ name: String, _ column: Column) throws -> UserDefaults {
    let suiteName = "ColumnWidthSettingTests.\(name).\(column.rawValue)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private static func stored(_ defaults: UserDefaults, _ column: Column) -> Double? {
    defaults.object(forKey: column.userDefaultsKey) as? Double
  }

  // MARK: - Constants

  @Test("keys, defaults and the sanity floor")
  func constants() {
    #expect(Column.content.userDefaultsKey == "content_column_width")
    #expect(Column.sidebar.userDefaultsKey == "sidebar_column_width")
    #expect(Column.content.defaultIdealWidth == 400)
    #expect(Column.sidebar.defaultIdealWidth == 238)
    #expect(Setting.sanityFloor == 100)
    #expect(Column.allCases.count == 2)
  }

  // MARK: - restoredIdealWidth

  @Test("an absent key restores the column default", arguments: Column.allCases)
  func absentKeyRestoresDefault(column: Column) throws {
    let defaults = try Self.makeSuite("absent", column)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == column.defaultIdealWidth)
  }

  @Test("a stored width is restored without a clamp: 900 stays 900, 150 stays 150", arguments: Column.allCases)
  func noClamp(column: Column) throws {
    let defaults = try Self.makeSuite("noClamp", column)
    defaults.set(900.0, forKey: column.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == 900)
    defaults.set(150.0, forKey: column.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == 150)
  }

  @Test("below the sanity floor, zero, negative, NaN and a wrong type restore the default", arguments: Column.allCases)
  func unusableValuesRestoreDefault(column: Column) throws {
    let defaults = try Self.makeSuite("unusable", column)
    for value in [50.0, 99.9, 0.0, -450.0] {
      defaults.set(value, forKey: column.userDefaultsKey)
      #expect(Setting.restoredIdealWidth(for: column, in: defaults) == column.defaultIdealWidth, "\(value)")
    }
    // A NaN may be rejected by the store or read back as NaN; both paths end
    // at the default.
    defaults.set(Double.nan, forKey: column.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == column.defaultIdealWidth)
    defaults.set("wide", forKey: column.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == column.defaultIdealWidth)
    defaults.set(100.0, forKey: column.userDefaultsKey)
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == 100, "floor is inclusive")
  }

  // MARK: - persist: check order

  @Test("the sanity floor beats every other rule", arguments: Column.allCases)
  func sanityFloorFirst(column: Column) throws {
    let defaults = try Self.makeSuite("floor", column)
    Setting.persist(450, for: column, isLaunchLayout: false, in: defaults)
    for launch in [true, false] {
      #expect(Setting.persist(80, for: column, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(99.9, for: column, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(0, for: column, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(.nan, for: column, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
      #expect(Setting.persist(.infinity, for: column, isLaunchLayout: launch, in: defaults) == .skippedBelowSanityFloor)
    }
    #expect(Self.stored(defaults, column) == 450)
  }

  @Test("equal-to-stored beats the launch layout: a healthy launch logs skippedEqualToStored", arguments: Column.allCases)
  func equalBeatsLaunch(column: Column) throws {
    // Fresh install: the launch layout at the default width is "equal".
    let fresh = try Self.makeSuite("equalFresh", column)
    #expect(Setting.persist(column.defaultIdealWidth, for: column, isLaunchLayout: true, in: fresh) == .skippedEqualToStored)
    #expect(Setting.persist(column.defaultIdealWidth + 0.5, for: column, isLaunchLayout: true, in: fresh) == .skippedEqualToStored)
    #expect(Self.stored(fresh, column) == nil)

    // Stored 586, platform lays out 586 at launch: equal, healthy.
    let stored = try Self.makeSuite("equalStored", column)
    Setting.persist(586, for: column, isLaunchLayout: false, in: stored)
    #expect(Setting.persist(586, for: column, isLaunchLayout: true, in: stored) == .skippedEqualToStored)
    #expect(Setting.persist(586.5, for: column, isLaunchLayout: true, in: stored) == .skippedEqualToStored)
    #expect(Setting.persist(586, for: column, isLaunchLayout: false, in: stored) == .skippedEqualToStored)
    #expect(Self.stored(stored, column) == 586)
  }

  @Test("the launch layout beats the store: a different first value is never written", arguments: Column.allCases)
  func launchBeatsStore(column: Column) throws {
    let fresh = try Self.makeSuite("launchFresh", column)
    #expect(Setting.persist(450, for: column, isLaunchLayout: true, in: fresh) == .skippedLaunchLayout)
    #expect(Setting.persist(200, for: column, isLaunchLayout: true, in: fresh) == .skippedLaunchLayout)
    #expect(Self.stored(fresh, column) == nil)

    // The mis-framed restore case: stored 586, platform lays out 348.
    let stored = try Self.makeSuite("launchStored", column)
    Setting.persist(586, for: column, isLaunchLayout: false, in: stored)
    #expect(Setting.persist(348, for: column, isLaunchLayout: true, in: stored) == .skippedLaunchLayout)
    #expect(Self.stored(stored, column) == 586)
  }

  @Test("a settled non-launch width is stored, rounded down, with no upper bound", arguments: Column.allCases)
  func storeRules(column: Column) throws {
    let defaults = try Self.makeSuite("store", column)
    #expect(Setting.persist(450, for: column, isLaunchLayout: false, in: defaults) == .stored(450))
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == 450)
    #expect(Setting.persist(450.5, for: column, isLaunchLayout: false, in: defaults) == .skippedEqualToStored)
    #expect(Setting.persist(519.9, for: column, isLaunchLayout: false, in: defaults) == .stored(519))
    #expect(Setting.persist(600.5, for: column, isLaunchLayout: false, in: defaults) == .stored(600))
    #expect(Setting.persist(1200, for: column, isLaunchLayout: false, in: defaults) == .stored(1200))
    #expect(Setting.restoredIdealWidth(for: column, in: defaults) == 1200)
    #expect(Setting.persist(100, for: column, isLaunchLayout: false, in: defaults) == .stored(100))
    #expect(Self.stored(defaults, column) == 100)
  }

  @Test("the two columns do not share a key")
  func columnsAreIndependent() throws {
    let defaults = try Self.makeSuite("independent", .content)
    Setting.persist(586, for: .content, isLaunchLayout: false, in: defaults)
    #expect(Setting.restoredIdealWidth(for: .content, in: defaults) == 586)
    #expect(Setting.restoredIdealWidth(for: .sidebar, in: defaults) == 238)
    Setting.persist(300, for: .sidebar, isLaunchLayout: false, in: defaults)
    #expect(Setting.restoredIdealWidth(for: .sidebar, in: defaults) == 300)
    #expect(Setting.restoredIdealWidth(for: .content, in: defaults) == 586)
  }
}
