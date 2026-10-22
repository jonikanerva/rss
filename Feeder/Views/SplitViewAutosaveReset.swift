import Foundation
import os

/// Removes AppKit's autosaved `NSSplitView` frames before each new main
/// window, so the `NavigationSplitView` finds none when it is created and
/// lays out both leading columns at the `ideal` widths Feeder stores itself
/// (`ColumnWidthSetting`).
///
/// `NSSplitView.autosaveName` is documented; the `UserDefaults` key NAME
/// ("NSSplitView Subview Frames <autosave name>") is not — this is a
/// reliance on undocumented AppKit behaviour, recorded in `STACK.md § 14`.
/// Failure mode: if a macOS release renames the key, the prefix matches
/// nothing and the removal is a no-op; `ColumnWidthRecorder`'s
/// launch-layout skip then protects the stored widths and logs the alarm.
/// `NSWindow Frame …` keys are never touched.
nonisolated enum SplitViewAutosaveReset {
  static let keyPrefix = "NSSplitView Subview Frames"

  /// Removes every key with `keyPrefix` from `defaults` and returns how many
  /// there were. Call BEFORE the split view of a new main window exists:
  /// `FeederApp.newMainWindowContent` calls it for the launch window, a Dock
  /// reopen, and Window → Feeder. AppKit writes a key again during the
  /// session, and a new window in the same launch restores that key unless
  /// this call removes it. One small-plist dictionary copy per call.
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
