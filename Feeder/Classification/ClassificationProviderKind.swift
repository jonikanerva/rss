import Foundation

/// Identifies the classification backend configured by the user.
/// Persisted to UserDefaults under `userDefaultsKey` using the raw value.
/// A stored value with no case, such as `openai`, resolves to `default`.
nonisolated enum ClassificationProviderKind: String, Sendable, CaseIterable {
  case appleFM = "apple_fm"
  case vercel = "vercel"

  static let userDefaultsKey = "classification_provider"
  static let `default`: Self = .appleFM

  /// The user's selected provider. A test passes an isolated suite, so two
  /// parallel suites cannot clobber each other through the shared domain.
  static func current(in defaults: UserDefaults = AppDefaults.current) -> Self {
    let stored = defaults.string(forKey: userDefaultsKey) ?? Self.default.rawValue
    return Self(rawValue: stored) ?? Self.default
  }

  /// Property-style alias, delegating to the injected form above so the
  /// `AppDefaults.current` read stays in one place.
  static var current: Self { current(in: AppDefaults.current) }

  /// Persist the user's provider selection. A test passes an isolated suite, so
  /// parallel suites do not race on the shared domain.
  static func persist(_ kind: Self, in defaults: UserDefaults = AppDefaults.current) {
    defaults.set(kind.rawValue, forKey: userDefaultsKey)
  }

  var keychainKey: String? {
    switch self {
    case .appleFM: nil
    case .vercel: KeychainHelper.vercelAPIKeychainKey
    }
  }

  // MARK: - Display

  var displayName: String {
    switch self {
    case .appleFM: "Apple Foundation Models"
    case .vercel: "Vercel AI Gateway"
    }
  }

  var subtitle: String {
    switch self {
    case .appleFM: "Free \u{00B7} On-device \u{00B7} Private"
    case .vercel: "Requires API key \u{00B7} Cloud-based"
    }
  }
}
