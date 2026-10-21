import Foundation
import Testing

@testable import Feeder

/// The unit-test host is a launch without the Feedbin account, so these tests
/// write only to the isolated suite and never read `UserDefaults.standard`.
@Suite("App defaults")
struct AppDefaultsTests {
  @Test(arguments: [["FEEDER_HEADLESS": "1"], ["XCODE_RUNNING_FOR_PREVIEWS": "1"]])
  func launchWithoutTheAccountUsesTheIsolatedSuite(_ environment: [String: String]) {
    #expect(AppDefaults.isolatedSuiteName(in: environment) == AppDefaults.isolatedSuiteDomain)
  }

  @Test
  func launchWithTheAccountUsesTheStandardDomain() {
    #expect(AppDefaults.isolatedSuiteName(in: [:]) == nil)
  }

  @Test
  func testHostWritesReachOnlyTheIsolatedSuite() throws {
    #expect(AppDefaults.isolatedSuiteName == AppDefaults.isolatedSuiteDomain)
    let suite = try #require(UserDefaults(suiteName: AppDefaults.isolatedSuiteDomain))
    let settingKey = "AppDefaultsTests.setting.\(UUID().uuidString)"
    let flagKey = "AppDefaultsTests.flag.\(UUID().uuidString)"
    // Also clean `AppDefaults.current`: a broken resolver writes to another
    // domain.
    defer {
      for defaults in [suite, AppDefaults.current] {
        defaults.removeObject(forKey: settingKey)
        defaults.removeObject(forKey: flagKey)
      }
    }

    AppDefaults.current.set(42, forKey: settingKey)
    AppDefaultsFlagStore().setSeeded(true, forKey: flagKey)

    #expect(suite.integer(forKey: settingKey) == 42)
    #expect(suite.bool(forKey: flagKey))
  }
}
