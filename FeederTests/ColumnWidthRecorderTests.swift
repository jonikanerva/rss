import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Headless check of `ColumnWidthRecorder` for both columns (issue #170): the
/// geometry observer, the launch-layout skip, the settle debounce and the
/// write reach an injected `UserDefaults` suite without a split view. Hosts a
/// view that fills an offscreen `NSHostingView`, resizes the host, and reads
/// the suite. `.serialized`: shares the offscreen-window hosting pattern with
/// `EntryRowGeometryTests`.
@Suite("Column width recorder", .serialized)
struct ColumnWidthRecorderTests {
  @Test(
    "the first settled width is the launch layout and is not stored; the next settled width is; the sanity floor holds",
    arguments: ColumnWidthSetting.Column.allCases)
  @MainActor
  func launchLayoutSkippedThenSettledWidthStored(column: ColumnWidthSetting.Column) async throws {
    let suiteName = "ColumnWidthRecorderTests.\(column.rawValue)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let key = column.userDefaultsKey

    let hosting = NSHostingView(
      rootView: Color.clear.modifier(ColumnWidthRecorder(column: column, defaults: defaults)))
    hosting.frame = NSRect(x: -6000, y: -6000, width: 450, height: 100)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()

    // First settled value = launch layout: nothing is written, even though
    // 450 differs from the column default.
    try await Task.sleep(for: .milliseconds(700))
    #expect(defaults.object(forKey: key) == nil, "launch layout must not be stored")

    // The launch flag flipped on that first settle: the next settled width
    // lands. (If this fails while the first check passed, `onGeometryChange`
    // did not report the initial layout and the flag never flipped.)
    Self.resize(window, hosting, to: 520)
    #expect(try await Self.storedValue(in: defaults, key: key, becomes: 520))

    // The sanity floor: a collapsed or hidden column is not stored.
    Self.resize(window, hosting, to: 80)
    try await Task.sleep(for: .milliseconds(600))
    #expect(defaults.object(forKey: key) as? Double == 520)

    // A later ordinary width is stored: the recorder is still live.
    Self.resize(window, hosting, to: 350)
    #expect(try await Self.storedValue(in: defaults, key: key, becomes: 350))
  }

  @MainActor
  private static func resize(_ window: NSWindow, _ hosting: NSHostingView<some View>, to width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: 100))
    hosting.frame.size.width = width
    hosting.layoutSubtreeIfNeeded()
  }

  /// Polls the suite until `key` holds `expected` or two seconds pass.
  /// Polling keeps the test independent of run-loop timing on a loaded
  /// machine; the debounce itself is 300 ms.
  @MainActor
  private static func storedValue(in defaults: UserDefaults, key: String, becomes expected: Double) async throws -> Bool {
    for _ in 0..<40 {
      if defaults.object(forKey: key) as? Double == expected { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return defaults.object(forKey: key) as? Double == expected
  }
}
