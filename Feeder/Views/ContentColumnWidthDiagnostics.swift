import Foundation
import os

/// Log lines for the content-column width (issue #170). Numbers and Bools
/// only (`STACK.md § 8`): no category labels, no paths, no article data.
/// `.notice` level on purpose: `.info` and `.debug` are not persisted to disk
/// by default, so `log show` after the owner's run would be empty.
///
/// Read with:
/// `log show --predicate 'subsystem == "com.feeder.app" AND category == "ContentColumnWidth"' --last 2h`
nonisolated enum ContentColumnWidthDiagnostics {
  static let logger = Logger(subsystem: "com.feeder.app", category: "ContentColumnWidth")

  /// D1, once per launch: the `ideal` handed to the split view and the raw
  /// stored value behind it. The one line that tells a future reader what
  /// the store held at launch.
  static func logRestoredIdeal(_ restored: CGFloat, in defaults: UserDefaults = .standard) {
    let raw = defaults.object(forKey: ContentColumnWidthSetting.userDefaultsKey) as? Double
    let rawText = raw.map { String($0) } ?? "absent"
    logger.notice("restored ideal=\(restored, privacy: .public) storedRaw=\(rawText, privacy: .public)")
  }
}
