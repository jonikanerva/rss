import Foundation
import SwiftUI
import Testing

@testable import Feeder

/// Every `SettingsPane.persist` call here passes `in: defaults`, and no test
/// writes `UserDefaults.standard`: the test host runs in the owner's real app
/// container.
@Suite("Settings pane")
final class SettingsPaneTests {
  private let suiteName = "FeederTests.SettingsPane.\(UUID().uuidString)"
  private let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: suiteName))
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }

  /// Must match the `@AppStorage` declaration in `SettingsView`: the same key
  /// and the same default value.
  private var storedPane: SettingsPane {
    AppStorage(wrappedValue: SettingsPane.default, SettingsPane.userDefaultsKey, store: defaults).wrappedValue
  }

  @Test(
    "a persisted pane reads back through AppStorage",
    arguments: [SettingsPane.account, .appearance, .sync, .categories, .classification])
  func persistedPaneReadsBack(pane: SettingsPane) {
    SettingsPane.persist(pane, in: defaults)
    #expect(defaults.string(forKey: SettingsPane.userDefaultsKey) == pane.rawValue)
    #expect(storedPane == pane)
  }

  @Test("an absent key reads as Account")
  func absentKeyReadsAsAccount() {
    #expect(defaults.object(forKey: SettingsPane.userDefaultsKey) == nil)
    #expect(storedPane == .account)
  }

  @Test("an unknown stored string reads as Account")
  func unknownValueReadsAsAccount() {
    defaults.set("general", forKey: SettingsPane.userDefaultsKey)
    #expect(storedPane == .account)
  }

  @Test("the key, the default, and the raw values are pinned")
  func storedIdentifiersArePinned() {
    #expect(SettingsPane.userDefaultsKey == "settings_pane")
    #expect(SettingsPane.default == .account)
    #expect(SettingsPane.account.rawValue == "account")
    #expect(SettingsPane.appearance.rawValue == "appearance")
    #expect(SettingsPane.sync.rawValue == "sync")
    #expect(SettingsPane.categories.rawValue == "categories")
    #expect(SettingsPane.classification.rawValue == "classification")
  }
}
