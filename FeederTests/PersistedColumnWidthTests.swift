import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Pins the modifier ORDER `persistedColumnWidth` encodes: the width
/// preference must be the outermost modifier on a column's content. An
/// `onGeometryChange` placed outside `navigationSplitViewColumnWidth` hides
/// the preference from the split view, and the column lays out at the
/// platform default. Hosts a three-column `NavigationSplitView` offscreen
/// and reads the backing `NSSplitView`'s arranged-subview frames.
///
/// Flake guards: a distinct root view TYPE per case (the bridge keys some
/// per-type state, incl. autosave, on the root type); the host is 1400 pt
/// wide, so sidebar + content + the detail minimum always fit; a 1-pt
/// tolerance for Retina half points; the negative control asserts "below
/// the ideal", not a platform-default constant; and every case checks that
/// the hosted split view added no `NSSplitView Subview Frames` key to the
/// test host's `UserDefaults.standard` (a later run would otherwise meet
/// AppKit's `width − x` restore). The check detects instead of deleting:
/// the test host shares its defaults domain with the installed app.
/// `.serialized`: shares the offscreen-window hosting pattern with
/// `EntryRowGeometryTests`.
@Suite("Persisted column width order", .serialized)
struct PersistedColumnWidthTests {
  private static let sidebarIdeal: CGFloat = 300
  private static let contentIdeal: CGFloat = 500
  private static let tolerance: CGFloat = 1
  private static let autosaveKeyPrefix = "NSSplitView Subview Frames"

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
    #expect(abs(widths.sidebar - Self.sidebarIdeal) <= Self.tolerance, "\(widths)")
    #expect(abs(widths.content - Self.contentIdeal) <= Self.tolerance, "\(widths)")
  }

  @Test("negative control: a recorder outside the preference hides it and the content falls to the default")
  @MainActor
  func recorderOutsideHidesPreference() async throws {
    let defaults = try Self.makeSuite("outside")
    let widths = try await Self.hostAndMeasure(RecorderOutsideSplit(defaults: defaults))
    #expect(abs(widths.sidebar - Self.sidebarIdeal) <= Self.tolerance, "\(widths)")
    #expect(widths.content < Self.contentIdeal - Self.tolerance, "the outer recorder must hide the preference: \(widths)")
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
    let autosaveKeysBefore = autosaveKeys()
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
    let added = autosaveKeys().subtracting(autosaveKeysBefore)
    #expect(added.isEmpty, "the hosted split view wrote autosave keys into the test host's defaults: \(added)")
    return ColumnWidths(sidebar: frames[0].width, content: frames[1].maxX - frames[0].maxX)
  }

  private static func autosaveKeys() -> Set<String> {
    Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(autosaveKeyPrefix) })
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
