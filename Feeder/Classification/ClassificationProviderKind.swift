import Foundation

/// Identifies the classification backend configured by the user.
/// Persisted to UserDefaults under `userDefaultsKey` using the raw value.
nonisolated enum ClassificationProviderKind: String, Sendable, CaseIterable {
  case appleFM = "apple_fm"
  case openAI = "openai"
  case vercel = "vercel"

  static let userDefaultsKey = "classification_provider"
  static let `default`: Self = .appleFM

  /// The user's selected provider. A test passes an isolated suite, so two
  /// parallel suites cannot clobber each other through the standard domain.
  static func current(in defaults: UserDefaults = .standard) -> Self {
    let stored = defaults.string(forKey: userDefaultsKey) ?? Self.default.rawValue
    return Self(rawValue: stored) ?? Self.default
  }

  /// Property-style alias, delegating to the injected form above so the
  /// standard-domain read stays in one place.
  static var current: Self { current(in: .standard) }

  /// Persist the user's provider selection. A test passes an isolated suite, so
  /// parallel suites do not race on the standard domain.
  static func persist(_ kind: Self, in defaults: UserDefaults = .standard) {
    defaults.set(kind.rawValue, forKey: userDefaultsKey)
  }

  var keychainKey: String? {
    switch self {
    case .appleFM: nil
    case .openAI: KeychainHelper.openAIAPIKeychainKey
    case .vercel: KeychainHelper.vercelAPIKeychainKey
    }
  }

  // MARK: - Display

  var displayName: String {
    switch self {
    case .appleFM: "Apple Foundation Models"
    case .openAI: "OpenAI"
    case .vercel: "Vercel AI Gateway"
    }
  }

  var subtitle: String {
    switch self {
    case .appleFM: "Free \u{00B7} On-device \u{00B7} Private"
    case .openAI, .vercel: "Requires API key \u{00B7} Cloud-based"
    }
  }

  var iconName: String {
    switch self {
    case .appleFM: "apple.logo"
    case .openAI, .vercel: "cloud"
    }
  }
}
