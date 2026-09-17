import Foundation
import os

/// Log lines for the split-view column widths (issue #170). Numbers, Bools
/// and the column key only (`STACK.md § 8`): no category labels, no paths, no
/// article data. `.notice` level on purpose: `.info` and `.debug` are not
/// persisted to disk by default, so `log show` after the owner's run would
/// be empty. The category name predates the sidebar column and is kept so
/// the owner's `log show` predicate stays valid.
///
/// Read with:
/// `log show --predicate 'subsystem == "com.feeder.app" AND category == "ContentColumnWidth"' --last 2h`
nonisolated enum ColumnWidthDiagnostics {
  static let logger = Logger(subsystem: "com.feeder.app", category: "ContentColumnWidth")

  /// D1, once per launch and column: the `ideal` handed to the split view and
  /// the raw stored value behind it. The one line that tells a future reader
  /// what the store held at launch.
  static func logRestoredIdeal(
    _ restored: CGFloat, for column: ColumnWidthSetting.Column, in defaults: UserDefaults = .standard
  ) {
    let raw = defaults.object(forKey: column.userDefaultsKey) as? Double
    let rawText = raw.map { String($0) } ?? "absent"
    logger.notice(
      "restored column=\(column.rawValue, privacy: .public) ideal=\(restored, privacy: .public) storedRaw=\(rawText, privacy: .public)"
    )
  }
}
