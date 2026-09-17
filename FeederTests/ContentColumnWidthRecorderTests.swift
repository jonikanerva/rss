import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Headless check of `ContentColumnWidthRecorder` (issue #170): the geometry
/// observer, the settle debounce and the write reach an injected
/// `UserDefaults` suite without a split view. Hosts a view that fills an
/// offscreen `NSHostingView`, resizes the host, and reads the suite.
/// `.serialized`: shares the offscreen-window hosting pattern with
/// `EntryRowGeometryTests`.
@Suite("Content column width recorder", .serialized)
struct ContentColumnWidthRecorderTests {
  private static let suiteName = "ContentColumnWidthRecorderTests"

  @Test("a settled in-range width is stored; an out-of-range resize is not; a later in-range width lands")
  @MainActor
  func settledWidthIsStored() async throws {
    let defaults = try #require(UserDefaults(suiteName: Self.suiteName))
    defaults.removePersistentDomain(forName: Self.suiteName)
    let key = ContentColumnWidthSetting.userDefaultsKey

    let hosting = NSHostingView(rootView: Color.clear.modifier(ContentColumnWidthRecorder(defaults: defaults)))
    hosting.frame = NSRect(x: -6000, y: -6000, width: 450, height: 100)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()

    // 300 ms settle + margin: the first in-range width lands.
    #expect(try await Self.storedValue(in: defaults, becomes: 450))

    // A squeezed / stretched layout outside the bounds must not overwrite it.
    window.setContentSize(NSSize(width: 700, height: 100))
    hosting.frame.size.width = 700
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(600))
    #expect(defaults.object(forKey: key) as? Double == 450)

    // A later in-range width is stored: the recorder is still live.
    window.setContentSize(NSSize(width: 350, height: 100))
    hosting.frame.size.width = 350
    hosting.layoutSubtreeIfNeeded()
    #expect(try await Self.storedValue(in: defaults, becomes: 350))
  }

  /// Polls the suite until the key holds `expected` or two seconds pass.
  /// Polling keeps the test independent of run-loop timing on a loaded
  /// machine; the debounce itself is 300 ms.
  @MainActor
  private static func storedValue(in defaults: UserDefaults, becomes expected: Double) async throws -> Bool {
    let key = ContentColumnWidthSetting.userDefaultsKey
    for _ in 0..<40 {
      if defaults.object(forKey: key) as? Double == expected { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return defaults.object(forKey: key) as? Double == expected
  }
}
