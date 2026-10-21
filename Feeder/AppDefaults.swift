import Foundation

/// The `UserDefaults` domain of this launch. A launch without the Feedbin
/// account (headless, previews) uses an isolated suite, so it never reads or
/// writes the owner's `UserDefaults.standard` domain. Read every app setting
/// and sync key through `current`. AppKit writes its split-view autosave keys
/// to `.standard` in every launch; `SplitViewAutosaveReset` owns those keys.
nonisolated enum AppDefaults {
  static let isolatedSuiteDomain = "donut.Feeder.accountless"

  /// `nil` for a launch with the Feedbin account. The first read empties the
  /// isolated suite, so each launch without the account starts from the
  /// defaults before any owner reads a value.
  static let isolatedSuiteName: String? = {
    guard let name = isolatedSuiteName(in: ProcessInfo.processInfo.environment) else { return nil }
    UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
    return name
  }()

  static func isolatedSuiteName(in environment: [String: String]) -> String? {
    FeederApp.usesFeedbinAccount(in: environment) ? nil : isolatedSuiteDomain
  }

  /// Resolved on each call: `UserDefaults` is not `Sendable`, so no global
  /// holds the instance.
  static var current: UserDefaults {
    isolatedSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}
