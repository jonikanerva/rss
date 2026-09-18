import Foundation
import Testing

@testable import Feeder

// MARK: - OpenAIModelSetting — absent-key default mechanism

/// The model key is written only on an explicit user pick, so an absent or
/// empty key must resolve to the current app default and a user who never
/// picked a model tracks a future default bump. A per-test isolated
/// `UserDefaults` suite keeps parallel suites off the standard domain.
@Suite("OpenAIModelSetting")
struct OpenAIModelSettingTests {
  private let defaults: UserDefaults

  init() {
    let id = "FeederTests.OpenAIModelSetting.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: id) else {
      fatalError("Failed to construct test-isolated UserDefaults suite \(id)")
    }
    self.defaults = defaults
  }

  /// An absent key resolves to the app default, so an unset user follows a
  /// default bump with no migration.
  @Test
  func absentKeyResolvesToDefaultModel() {
    #expect(defaults.string(forKey: OpenAIModelSetting.userDefaultsKey) == nil)
    #expect(OpenAIModelSetting.current(in: defaults) == "gpt-5.6-luna")
  }

  /// An empty stored string is treated identically to "no pick": fall back
  /// to the default rather than sending an empty model id to the API.
  @Test
  func emptyStoredValueResolvesToDefaultModel() {
    defaults.set("", forKey: OpenAIModelSetting.userDefaultsKey)
    #expect(OpenAIModelSetting.current(in: defaults) == OpenAIModelSetting.defaultModel)
  }

  /// Roundtrip: an explicit pick persists and resolves verbatim.
  @Test
  func persistedPickRoundtrips() {
    OpenAIModelSetting.persist("gpt-example-custom", in: defaults)
    #expect(OpenAIModelSetting.current(in: defaults) == "gpt-example-custom")
  }
}
