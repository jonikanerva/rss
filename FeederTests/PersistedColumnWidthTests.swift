import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Pins the modifier ORDER `persistedColumnWidth` encodes (issue #170): the
/// width preference must be the outermost modifier on a column's content.
/// Measured on macOS 27 (headless spike, 2026-09-17): an `onGeometryChange`
/// placed outside `navigationSplitViewColumnWidth` hides the preference from
/// the split view, and the column lays out at the platform default. Hosts a
/// three-column `NavigationSplitView` offscreen and reads the backing
/// `NSSplitView`'s arranged-subview frames. `.serialized`: shares the
/// offscreen-window hosting pattern with `EntryRowGeometryTests`.
@Suite("Persisted column width order", .serialized)
struct PersistedColumnWidthTests {
  private static let sidebarIdeal: CGFloat = 300
  private static let contentIdeal: CGFloat = 500

  /// Both columns through the extension: the ideals govern.
  private struct OrderedSplit: View {
    let defaults: UserDefaults
    var body: some View {
      NavigationSplitView {
        List {
          Text("A")
          Text("B")
        }
        .persistedColumnWidth(column: .sidebar, ideal: sidebarIdeal, defaults: defaults)
      } content: {
        ZStack {
          Color.clear
        }
        .persistedColumnWidth(column: .content, ideal: contentIdeal, defaults: defaults)
      } detail: {
        Color.clear
      }
    }
  }

  /// Negative control: the recorder OUTSIDE the preference on the content
  /// column. Documents the constraint; the content falls to the default.
  private struct RecorderOutsideSplit: View {
    let defaults: UserDefaults
    var body: some View {
      NavigationSplitView {
        List {
          Text("A")
          Text("B")
        }
        .persistedColumnWidth(column: .sidebar, ideal: sidebarIdeal, defaults: defaults)
      } content: {
        ZStack {
          Color.clear
        }
        .navigationSplitViewColumnWidth(ideal: contentIdeal)
        .modifier(ColumnWidthRecorder(column: .content, defaults: defaults))
      } detail: {
        Color.clear
      }
    }
  }

  @Test("the extension keeps both ideals: sidebar 300, content 500")
  @MainActor
  func extensionAppliesBothIdeals() async throws {
    let defaults = try Self.makeSuite("ordered")
    let widths = try await Self.hostAndMeasure(OrderedSplit(defaults: defaults))
    #expect(widths.sidebar == Self.sidebarIdeal, "\(widths)")
    #expect(widths.content == Self.contentIdeal, "\(widths)")
  }

  @Test("negative control: a recorder outside the preference hides it and the content falls to the default")
  @MainActor
  func recorderOutsideHidesPreference() async throws {
    let defaults = try Self.makeSuite("outside")
    let widths = try await Self.hostAndMeasure(RecorderOutsideSplit(defaults: defaults))
    #expect(widths.sidebar == Self.sidebarIdeal, "\(widths)")
    #expect(widths.content != Self.contentIdeal, "the outer recorder must hide the preference: \(widths)")
    #expect(widths.content < Self.contentIdeal, "\(widths)")
  }

  // MARK: - Hosting

  private struct ColumnWidths: CustomStringConvertible {
    let sidebar: CGFloat
    let content: CGFloat
    var description: String { "sidebar \(sidebar) content \(content)" }
  }

  /// Hosts `root` offscreen at 1400 × 800, lets the bridge lay out and settle,
  /// and reads the sidebar and content widths from the `NSSplitView`. The
  /// arranged subviews' frames run from x = 0: the content width is its
  /// `maxX` minus the sidebar's `maxX`.
  @MainActor
  private static func hostAndMeasure(_ root: some View) async throws -> ColumnWidths {
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: -6000, y: -6000, width: 1400, height: 800)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()
    // Past the recorder's 300 ms settle, so the launch layout has been seen.
    try await Task.sleep(for: .milliseconds(600))
    hosting.layoutSubtreeIfNeeded()
    let split = try #require(findSplitViews(in: hosting).first, "no NSSplitView under the hosting view")
    let frames = split.arrangedSubviews.map(\.frame)
    try #require(frames.count == 3, "expected three arranged subviews, got \(frames.count)")
    return ColumnWidths(sidebar: frames[0].width, content: frames[1].maxX - frames[0].maxX)
  }

  @MainActor
  private static func findSplitViews(in view: NSView) -> [NSSplitView] {
    var result: [NSSplitView] = []
    if let split = view as? NSSplitView { result.append(split) }
    for subview in view.subviews {
      result.append(contentsOf: findSplitViews(in: subview))
    }
    return result
  }

  private static func makeSuite(_ name: String) throws -> UserDefaults {
    let suiteName = "PersistedColumnWidthTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
