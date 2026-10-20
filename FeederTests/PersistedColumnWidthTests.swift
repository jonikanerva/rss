import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Pins the modifier order `persistedColumnWidth` encodes: the width preference
/// must be the outermost modifier on a column's content, because a geometry
/// observer placed outside it hides the preference from the split view and the
/// column lays out at the platform default. It hosts a split view offscreen and
/// reads the backing arranged-subview frames.
///
/// The flake guards: a distinct root view type per case, because the bridge keys
/// per-type state on it; a host wide enough that every column fits; a one-point
/// tolerance for Retina half points; a negative control that asserts "below the
/// ideal" rather than a platform constant; and a check that the hosted split
/// view added no autosave key to the test host's defaults, which a later run
/// would otherwise restore from. The check detects rather than deletes, because
/// the test host shares its defaults domain with the installed app.
@Suite("Persisted column width order", .serialized)
@MainActor
struct PersistedColumnWidthTests {
  private static let sidebarIdeal: CGFloat = 300
  private static let contentIdeal: CGFloat = 500
  private static let tolerance: CGFloat = 1
  private static let autosaveKeyPrefix = "NSSplitView Subview Frames"
  /// How long after the stable layout the autosave-key check can still catch
  /// a write by the split-view bridge. The `STACK.md § 3` sleep limit caps it.
  private static let quietWindow: Duration = .milliseconds(100)
  /// Upper bound for the split view to appear with a stable layout.
  private static let layoutDeadline: Duration = .seconds(2)

  private let isolatedDefaults: IsolatedDefaults

  init() throws {
    isolatedDefaults = try IsolatedDefaults("PersistedColumnWidth")
  }

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
  func extensionAppliesBothIdeals() async throws {
    let widths = try await Self.hostAndMeasure(OrderedSplit(defaults: isolatedDefaults.defaults))
    #expect(abs(widths.sidebar - Self.sidebarIdeal) <= Self.tolerance, "\(widths)")
    #expect(abs(widths.content - Self.contentIdeal) <= Self.tolerance, "\(widths)")
  }

  @Test("negative control: a recorder outside the preference hides it and the content falls to the default")
  func recorderOutsideHidesPreference() async throws {
    let widths = try await Self.hostAndMeasure(RecorderOutsideSplit(defaults: isolatedDefaults.defaults))
    #expect(abs(widths.sidebar - Self.sidebarIdeal) <= Self.tolerance, "\(widths)")
    #expect(widths.content < Self.contentIdeal - Self.tolerance, "the outer recorder must hide the preference: \(widths)")
  }

  // MARK: - Hosting

  private struct ColumnWidths: CustomStringConvertible {
    let sidebar: CGFloat
    let content: CGFloat
    var description: String { "sidebar \(sidebar) content \(content)" }
  }

  /// Hosts `root` offscreen at 1400 × 800, waits for a stable split-view
  /// layout and then for `quietWindow`, and reads the sidebar and content
  /// widths from the `NSSplitView`. The arranged subviews' frames run from
  /// x = 0: the content width is its `maxX` minus the sidebar's `maxX`.
  private static func hostAndMeasure(_ root: some View) async throws -> ColumnWidths {
    let autosaveKeysBefore = autosaveKeys()
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: -6000, y: -6000, width: 1400, height: 800)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let stableFrames = try await stableSplitFrames(in: hosting)
    try #require(stableFrames.count == 3, "no stable NSSplitView with three arranged subviews: \(stableFrames)")
    try await Task.sleep(for: quietWindow)
    hosting.layoutSubtreeIfNeeded()
    let split = try #require(findSplitViews(in: hosting).first, "no NSSplitView under the hosting view")
    let frames = split.arrangedSubviews.map(\.frame)
    try #require(frames.count == 3, "expected three arranged subviews, got \(frames.count)")
    let added = autosaveKeys().subtracting(autosaveKeysBefore)
    #expect(added.isEmpty, "the hosted split view wrote autosave keys into the test host's defaults: \(added)")
    return ColumnWidths(sidebar: frames[0].width, content: frames[1].maxX - frames[0].maxX)
  }

  /// Lays out `hosting` until its split view has three arranged subviews with
  /// the same frames on two passes in a row, or until `layoutDeadline`. Returns
  /// the stable frames, or an empty array when the deadline passes first.
  private static func stableSplitFrames(in hosting: NSView) async throws -> [NSRect] {
    let deadline = ContinuousClock.now + layoutDeadline
    var previous: [NSRect] = []
    while ContinuousClock.now < deadline {
      hosting.layoutSubtreeIfNeeded()
      let frames = findSplitViews(in: hosting).first?.arrangedSubviews.map(\.frame) ?? []
      if frames.count == 3, frames == previous { return frames }
      previous = frames
      try await Task.sleep(for: .milliseconds(10))
    }
    return []
  }

  /// The split-view bridge writes its autosave frames to `UserDefaults.standard`
  /// and takes no injected store, so the check reads the test host's defaults.
  private static func autosaveKeys() -> Set<String> {
    Set(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix(autosaveKeyPrefix) })
  }

  private static func findSplitViews(in view: NSView) -> [NSSplitView] {
    var result: [NSSplitView] = []
    if let split = view as? NSSplitView { result.append(split) }
    for subview in view.subviews {
      result.append(contentsOf: findSplitViews(in: subview))
    }
    return result
  }
}
