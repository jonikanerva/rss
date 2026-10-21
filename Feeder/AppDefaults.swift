import Foundation

/// The `UserDefaults` domain of this launch (`STACK.md § 3` → hygiene). Read
/// every app setting and sync key through `current`.
nonisolated enum AppDefaults {
  static let isolatedSuiteDomain = "donut.Feeder.accountless"

  /// `nil` for a launch with the Feedbin account. Keep it a `static let`: the
  /// suite empty must run once, before any owner reads a value.
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
