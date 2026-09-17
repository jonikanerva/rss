import Foundation
import Testing

@testable import Feeder

/// Pins `SplitViewAutosaveReset` (issue #170): only keys with the
/// `NSSplitView Subview Frames` prefix are removed; window-frame keys and
/// Feeder's own width keys stay; the count is exact.
@Suite("Split view autosave reset")
struct SplitViewAutosaveResetTests {
  private static func makeSuite(_ name: String) throws -> UserDefaults {
    let suiteName = "SplitViewAutosaveResetTests.\(name)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("removes only the prefixed key and reports 1")
  func removesOnlyPrefixedKey() throws {
    let defaults = try Self.makeSuite("one")
    let frameKey = "NSSplitView Subview Frames SomeRootType-1-AppWindow-1, SidebarNavigationSplitView"
    defaults.set(["0.000000, 0.000000, 238.000000, 800.000000, NO, NO"], forKey: frameKey)
    defaults.set("100 100 1400 800 0 0 1728 1079", forKey: "NSWindow Frame Feeder")
    defaults.set(586.0, forKey: ColumnWidthSetting.Column.content.userDefaultsKey)

    #expect(SplitViewAutosaveReset.removeStaleFrames(in: defaults) == 1)
    #expect(defaults.object(forKey: frameKey) == nil)
    #expect(defaults.string(forKey: "NSWindow Frame Feeder") == "100 100 1400 800 0 0 1728 1079")
    #expect(defaults.double(forKey: ColumnWidthSetting.Column.content.userDefaultsKey) == 586)
  }

  @Test("an empty suite reports 0")
  func emptySuiteReportsZero() throws {
    let defaults = try Self.makeSuite("empty")
    #expect(SplitViewAutosaveReset.removeStaleFrames(in: defaults) == 0)
  }

  @Test("every prefixed key goes, whatever its suffix")
  func removesEveryPrefixedKey() throws {
    let defaults = try Self.makeSuite("many")
    defaults.set(["a"], forKey: "NSSplitView Subview Frames A")
    defaults.set(["b"], forKey: "NSSplitView Subview Frames B-2-AppWindow-2, SidebarNavigationSplitView")
    defaults.set(["c"], forKey: "Other NSSplitView Subview Frames")
    #expect(SplitViewAutosaveReset.removeStaleFrames(in: defaults) == 2)
    #expect(defaults.object(forKey: "NSSplitView Subview Frames A") == nil)
    #expect(defaults.object(forKey: "NSSplitView Subview Frames B-2-AppWindow-2, SidebarNavigationSplitView") == nil)
    #expect(defaults.object(forKey: "Other NSSplitView Subview Frames") != nil, "prefix match only")
    #expect(SplitViewAutosaveReset.removeStaleFrames(in: defaults) == 0, "second call finds nothing")
  }
}
