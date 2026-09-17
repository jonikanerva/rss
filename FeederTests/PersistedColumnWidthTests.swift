import AppKit
import SwiftUI
import Testing

@testable import Feeder

/// Pins the modifier ORDER `persistedColumnWidth(ideal:)` encodes (issue
/// #170): the width preference must be the outermost modifier on a column's
/// content. Measured on macOS 27 (headless spike, 2026-09-17): an
/// `onGeometryChange` placed outside `navigationSplitViewColumnWidth` hides
/// the preference from the split view, and the column lays out at the
/// platform default. Hosts a three-column `NavigationSplitView` offscreen and
/// reads the backing `NSSplitView`'s arranged-subview frames.
///
/// Flake guards: a distinct root view TYPE per case (the bridge keys some
/// per-type state, incl. autosave, on the root type); the host is 1400 pt
/// wide, so sidebar + content + the detail minimum always fit; a 1-pt
/// tolerance for Retina half points; the negative control asserts "below
/// the ideal", not a platform-default constant; and every case checks that
/// the hosted split view added no `NSSplitView Subview Frames` key to the
/// test host's `UserDefaults.standard` (a later run would otherwise meet
/// AppKit's `width − x` restore). The check detects instead of deleting:
/// the test host shares its defaults domain with the installed app, and the
/// app's sidebar relies on that autosave. `.serialized`: shares the
/// offscreen-window hosting pattern with `EntryRowGeometryTests`.
@Suite("Persisted column width order", .serialized)
struct PersistedColumnWidthTests {
  private static let contentIdeal: CGFloat = 500
  private static let tolerance: CGFloat = 1
  private static let autosaveKeyPrefix = "NSSplitView Subview Frames"

  /// The content column through the extension: the ideal governs.
  private struct OrderedSplit: View {
    let defaults: UserDefaults
    var body: some View {
      NavigationSplitView {
        List {
          Text("A")
          Text("B")
        }
      } content: {
        ZStack {
          Color.clear
        }
        .persistedColumnWidth(ideal: contentIdeal, defaults: defaults)
      } detail: {
        Color.clear
      }
    }
  }

  /// Negative control: the recorder OUTSIDE the preference on the content
  /// column. Documents the constraint; the content falls below the ideal.
  private struct RecorderOutsideSplit: View {
    let defaults: UserDefaults
    var body: some View {
      NavigationSplitView {
        List {
          Text("A")
          Text("B")
        }
      } content: {
        ZStack {
          Color.clear
        }
        .navigationSplitViewColumnWidth(ideal: contentIdeal)
        .modifier(ContentColumnWidthRecorder(defaults: defaults))
      } detail: {
        Color.clear
      }
    }
  }

  @Test("the extension keeps the content ideal: 500 within 1 pt")
  @MainActor
  func extensionAppliesIdeal() async throws {
    let defaults = try Self.makeSuite("ordered")
    let content = try await Self.hostAndMeasureContent(OrderedSplit(defaults: defaults))
    #expect(abs(content - Self.contentIdeal) <= Self.tolerance, "content \(content)")
  }

  @Test("negative control: a recorder outside the preference hides it and the content falls below the ideal")
  @MainActor
  func recorderOutsideHidesPreference() async throws {
    let defaults = try Self.makeSuite("outside")
    let content = try await Self.hostAndMeasureContent(RecorderOutsideSplit(defaults: defaults))
    #expect(content < Self.contentIdeal - Self.tolerance, "the outer recorder must hide the preference: content \(content)")
  }

  // MARK: - Hosting

  /// Hosts `root` offscreen at 1400 × 800, lets the bridge lay out and settle
  /// past the recorder's 300 ms debounce, and reads the content width from
  /// the `NSSplitView`. The arranged subviews' frames run from x = 0: the
  /// content width is its `maxX` minus the sidebar's `maxX`. Fails if the
  /// hosted split view wrote an autosave key into the test host's defaults.
  @MainActor
  private static func hostAndMeasureContent(_ root: some View) async throws -> CGFloat {
    let autosaveKeysBefore = autosaveKeys()
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: -6000, y: -6000, width: 1400, height: 800)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    hosting.layoutSubtreeIfNeeded()
    // Same rhythm as the geometry tests: one run-loop turn for the bridge,
    // then a second layout pass; 600 ms is past the recorder's settle.
    try await Task.sleep(for: .milliseconds(200))
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(400))
    hosting.layoutSubtreeIfNeeded()
    let split = try #require(findSplitViews(in: hosting).first, "no NSSplitView under the hosting view")
    let frames = split.arrangedSubviews.map(\.frame)
    try #require(frames.count == 3, "expected three arranged subviews, got \(frames.count)")
    let added = autosaveKeys().subtracting(autosaveKeysBefore)
    #expect(added.isEmpty, "the hosted split view wrote autosave keys into the test host's defaults: \(added)")
    return frames[1].maxX - frames[0].maxX
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
