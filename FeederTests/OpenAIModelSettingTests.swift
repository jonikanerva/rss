import Foundation
import Testing

@testable import Feeder

// MARK: - OpenAIModelSetting — absent-key default mechanism

/// Pins the stage-1 mechanism of issue #175: the `openai_model` key is
/// written only on an explicit user pick, so an absent (or empty) key must
/// resolve to the current app default — users who never picked a model track
/// future default bumps automatically. Uses a per-test isolated
/// `UserDefaults(suiteName:)` (the `ClassificationProviderResolutionTests`
/// pattern) so parallel suites never clobber each other through `.standard`.
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

  /// Absent key → the app default. This is the load-bearing default bump of
  /// issue #175 stage 1: unset users get gpt-5.6-luna without any migration.
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
