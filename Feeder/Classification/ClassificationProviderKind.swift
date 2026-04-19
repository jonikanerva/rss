import Foundation

/// Identifies the classification backend configured by the user.
/// Persisted to UserDefaults under `userDefaultsKey` using the raw value.
nonisolated enum ClassificationProviderKind: String, Sendable, CaseIterable {
  case appleFM = "apple_fm"
  case openAI = "openai"

  static let userDefaultsKey = "classification_provider"
  static let `default`: Self = .appleFM

  static var current: Self {
    let stored = UserDefaults.standard.string(forKey: userDefaultsKey) ?? Self.default.rawValue
    return Self(rawValue: stored) ?? Self.default
  }

  static func persist(_ kind: Self) {
    UserDefaults.standard.set(kind.rawValue, forKey: userDefaultsKey)
  }
}
