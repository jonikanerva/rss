import Foundation
import Testing

/// Owns one `UserDefaults` suite with a unique name, and removes the suite in
/// `deinit`. Store the owner in the test suite, so that it lives until the
/// test's last write: a write after the removal creates the suite again.
final class IsolatedDefaults {
  let defaults: UserDefaults
  private let suiteName: String

  init(_ label: String) throws {
    let suiteName = "FeederTests.\(label).\(UUID().uuidString)"
    self.suiteName = suiteName
    defaults = try #require(UserDefaults(suiteName: suiteName))
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}
