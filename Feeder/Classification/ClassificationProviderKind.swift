import Foundation

/// Identifies the classification backend configured by the user.
/// Persisted to UserDefaults under `userDefaultsKey` using the raw value.
nonisolated enum ClassificationProviderKind: String, Sendable, CaseIterable {
  case appleFM = "apple_fm"
  case openAI = "openai"

  static let userDefaultsKey = "classification_provider"
  static let `default`: Self = .appleFM

  /// Production callers read the user's currently-selected provider from
  /// `UserDefaults.standard`. Tests pass an isolated `UserDefaults` suite —
  /// mirroring the precedent set by `SyncEngine(defaults:)` — so two
  /// `@Suite` cases running in parallel cannot clobber each other's stored
  /// value via the shared standard domain.
  static func current(in defaults: UserDefaults = .standard) -> Self {
    let stored = defaults.string(forKey: userDefaultsKey) ?? Self.default.rawValue
    return Self(rawValue: stored) ?? Self.default
  }

  /// Convenience alias for production call sites that read the property-style
  /// API (`ClassificationProviderKind.current`). Delegates to the
  /// `UserDefaults`-injected form above so the standard-domain read stays
  /// in exactly one place.
  static var current: Self { current(in: .standard) }

  /// Persist the user's provider selection. Defaults to `UserDefaults.standard`
  /// for production call sites; tests pass an isolated suite to avoid racing
  /// with parallel suite cases on the shared standard domain.
  static func persist(_ kind: Self, in defaults: UserDefaults = .standard) {
    defaults.set(kind.rawValue, forKey: userDefaultsKey)
  }

  // MARK: - Display

  var displayName: String {
    switch self {
    case .appleFM: "Apple Foundation Models"
    case .openAI: "OpenAI GPT-5.4-nano"
    }
  }

  var subtitle: String {
    switch self {
    case .appleFM: "Free \u{00B7} On-device \u{00B7} Private"
    case .openAI: "Requires API key \u{00B7} Cloud-based"
    }
  }

  var iconName: String {
    switch self {
    case .appleFM: "apple.logo"
    case .openAI: "cloud"
    }
  }
}
