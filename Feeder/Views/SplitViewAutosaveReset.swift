import Foundation
import os

/// Removes AppKit's autosaved `NSSplitView` frames at launch (issue #170), so
/// the `NavigationSplitView` finds none when it is created and lays out both
/// leading columns at the `ideal` widths Feeder stores itself
/// (`ColumnWidthSetting`).
///
/// Measured mechanism (macOS 27, five-launch log on #170): the bridge
/// autosaves the content column's frame with `x` = the sidebar width and
/// restores the column as `width − x`, overriding the launch `ideal` about
/// half a second after the split view is created; the sidebar has `x = 0`
/// and restores correctly. A late `ideal` change is ignored (headless spike),
/// so the only way to keep the stored width is to remove the frames before
/// the split view exists.
///
/// `NSSplitView.autosaveName` is documented; the `UserDefaults` key NAME
/// ("NSSplitView Subview Frames <autosave name>") is not — this is a reliance
/// on undocumented AppKit behaviour, recorded in `STACK.md § 14`. Failure
/// mode: if a macOS release renames the key, the prefix matches nothing, the
/// removal is a no-op, today's defect returns, and nothing worse happens
/// (`ColumnWidthRecorder`'s launch-layout skip then protects the stored
/// widths and logs the alarm). `NSWindow Frame …` keys are never touched.
nonisolated enum SplitViewAutosaveReset {
  static let keyPrefix = "NSSplitView Subview Frames"

  /// Removes every key with `keyPrefix` from `defaults` and returns how many
  /// there were. Call BEFORE any window or split view exists — the first
  /// statement of `FeederApp.init`. One small-plist dictionary copy per
  /// launch. AppKit writes a key again during the session; it is removed
  /// again at the next launch.
  @discardableResult
  static func removeStaleFrames(in defaults: UserDefaults = .standard) -> Int {
    let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }
    for key in keys {
      defaults.removeObject(forKey: key)
    }
    ColumnWidthDiagnostics.logger.notice(
      "removed autosaved split-view frame sets: \(keys.count, privacy: .public)")
    return keys.count
  }
}
