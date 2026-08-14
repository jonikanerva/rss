import Foundation

/// Stores the user's OpenAI classification model selection in UserDefaults.
///
/// Absent-key semantics are the default mechanism: the key is written ONLY
/// on an explicit user pick in Settings (`ClassificationSettingsView` is the
/// single `persist` call site), so users who never picked a model
/// automatically track future app-default bumps. Nothing about the fetched
/// model catalog is ever persisted — only the user's own pick.
nonisolated enum OpenAIModelSetting {
  static let userDefaultsKey = "openai_model"
  static let defaultModel = "gpt-5.6-luna"

  /// The effective model: the stored pick, or `defaultModel` when the key is
  /// absent or empty. Production callers read `UserDefaults.standard`; tests
  /// pass an isolated suite (the `ClassificationProviderKind` pattern).
  static func current(in defaults: UserDefaults = .standard) -> String {
    guard let stored = defaults.string(forKey: userDefaultsKey), !stored.isEmpty else {
      return defaultModel
    }
    return stored
  }

  /// Persist an explicit user pick. Never called programmatically — writing
  /// the key pins the user to that model across future app-default bumps.
  static func persist(_ model: String, in defaults: UserDefaults = .standard) {
    defaults.set(model, forKey: userDefaultsKey)
  }
}
