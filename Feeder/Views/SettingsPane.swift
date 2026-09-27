import Foundation

/// A pane of the Settings window. The raw value is the stored identifier, so
/// renaming a case resets a stored pane to `default`.
nonisolated enum SettingsPane: String, Sendable {
  case account
  case appearance
  case sync
  case categories
  case classification

  static let userDefaultsKey = "settings_pane"
  static let `default`: Self = .account

  static func persist(_ pane: Self, in defaults: UserDefaults = .standard) {
    defaults.set(pane.rawValue, forKey: userDefaultsKey)
  }
}
