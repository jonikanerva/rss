import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Headless check of `ColumnWidthRecorder` for both columns in the shipped
/// shape, `persistedColumnWidth(column:ideal:)`: the geometry observer, the
/// launch-layout skip, the width-only debounce key and the settle debounce
/// reach an injected `UserDefaults` suite without a split view. `.serialized`:
/// shares the offscreen-window hosting pattern with `EntryRowGeometryTests`.
@Suite("Column width recorder", .serialized)
struct ColumnWidthRecorderTests {
  /// Drives the recorder's width and leading edge independently inside a
  /// fixed-size host: a leading spacer moves the recorded view, a fixed
  /// frame sets its width, a trailing spacer absorbs the rest. No host
  /// resize, so an x-only step never passes through a transient width.
  @MainActor
  @Observable
  final class GeometryBox {
    var leading: CGFloat = 0
    var width: CGFloat = 450
  }

  private struct GeometryHost: View {
    let box: GeometryBox
    let column: ColumnWidthSetting.Column
    let defaults: UserDefaults
    var body: some View {
      HStack(spacing: 0) {
        Color.clear.frame(width: box.leading)
        Color.clear
          .frame(width: box.width)
          .persistedColumnWidth(column: column, ideal: 400, defaults: defaults)
        Color.clear
      }
    }
  }

  @Test(
    "first settled width skipped; an x-only move stores nothing; a width change stores; the sanity floor holds",
    arguments: ColumnWidthSetting.Column.allCases)
  @MainActor
  func launchSkipThenWidthOnlyTrigger(column: ColumnWidthSetting.Column) async throws {
    let suiteName = "ColumnWidthRecorderTests.\(column.rawValue)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let key = column.userDefaultsKey
    let box = GeometryBox()

    let hosting = NSHostingView(rootView: GeometryHost(box: box, column: column, defaults: defaults))
    hosting.frame = NSRect(x: -6000, y: -6000, width: 900, height: 100)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()

    // First settled value = launch layout. 450 differs from the default, so
    // the only outcome that leaves the key absent is `skippedLaunchLayout`.
    try await Task.sleep(for: .milliseconds(700))
    #expect(defaults.object(forKey: key) == nil, "launch layout must not be stored")

    // The leading edge moves while the width stays put. The debounce must not
    // re-arm, so the still-launch-shaped width is not stored.
    box.leading = 100
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(700))
    #expect(defaults.object(forKey: key) == nil, "an x-only change must not persist")

    // A width change stores: the launch flag flipped on the first settle.
    box.width = 520
    hosting.layoutSubtreeIfNeeded()
    #expect(try await Self.storedValue(in: defaults, key: key, becomes: 520))

    // The sanity floor: a collapsed or hidden column is not stored.
    box.width = 80
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(600))
    #expect(defaults.object(forKey: key) as? Double == 520)

    // A later ordinary width is stored: the recorder is still live.
    box.width = 350
    hosting.layoutSubtreeIfNeeded()
    #expect(try await Self.storedValue(in: defaults, key: key, becomes: 350))
  }

  /// Polls the suite until `key` holds `expected` or two seconds pass.
  /// Polling keeps the test independent of run-loop timing on a loaded
  /// machine; the debounce itself is 150 ms.
  @MainActor
  private static func storedValue(in defaults: UserDefaults, key: String, becomes expected: Double) async throws -> Bool {
    for _ in 0..<40 {
      if defaults.object(forKey: key) as? Double == expected { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return defaults.object(forKey: key) as? Double == expected
  }
}
