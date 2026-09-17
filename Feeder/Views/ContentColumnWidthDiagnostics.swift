import Foundation
import os

/// Log lines for the content-column width investigation (issue #170). Numbers
/// and Bools only (`STACK.md § 8`): no category labels, no paths, no article
/// data. `.notice` level on purpose: `.info` and `.debug` are not persisted to
/// disk by default, so `log show` after the owner's run would be empty.
///
/// Read with:
/// `log show --predicate 'subsystem == "com.feeder.app" AND category == "ContentColumnWidth"' --last 2h`
nonisolated enum ContentColumnWidthDiagnostics {
  static let logger = Logger(subsystem: "com.feeder.app", category: "ContentColumnWidth")

  /// D1, once per launch: the `ideal` handed to the split view and the raw
  /// stored value behind it. Keeps after the investigation: it is the one
  /// line that tells a future reader what the store held at launch.
  static func logRestoredIdeal(_ restored: CGFloat, in defaults: UserDefaults = .standard) {
    let raw = defaults.object(forKey: ContentColumnWidthSetting.userDefaultsKey) as? Double
    let rawText = raw.map { String($0) } ?? "absent"
    logger.notice("restored ideal=\(restored, privacy: .public) storedRaw=\(rawText, privacy: .public)")
  }

  // Diagnostic for issue #170 — remove before merge.
  /// D2, once per launch: every autosaved `NSSplitView` frame set in the
  /// app's defaults. The key is a SwiftUI type name and the value is a list
  /// of frame strings; neither is user data.
  static func logSplitViewAutosaveFrames(in defaults: UserDefaults = .standard) {
    let frames = defaults.dictionaryRepresentation()
      .filter { $0.key.hasPrefix("NSSplitView Subview Frames") }
      .sorted { $0.key < $1.key }
    if frames.isEmpty {
      logger.notice("autosave frames: none")
      return
    }
    for (key, value) in frames {
      logger.notice("autosave \(key, privacy: .public) = \(String(describing: value), privacy: .public)")
    }
  }
}
