import XCTest

/// Deterministic layout invariants for the article list (issue #170), one
/// trial each. The N=30 measurement that sized these lives on the issue.
///
/// - The content column stays inside its width bound (320...600) after a
///   sidebar toggle, after a window resize, and after a divider drag toward
///   the sidebar.
/// - After the empty-category -> populated-category swap (the transition
///   that reproduced clipped rows in 26 of 30 trials before the fix), the row
///   pitch equals the row-height floor: the floor is the row height, so a
///   lost row re-measure in the `List` bridge has nothing left to clip.
final class EntryListLayoutUITests: XCTestCase {
  /// `ContentView.contentColumnMinWidth` / `contentColumnMaxWidth`.
  private static let contentColumnMinWidth: CGFloat = 320
  private static let contentColumnMaxWidth: CGFloat = 600
  /// Tolerance for point values read through the accessibility frames.
  private static let tolerance: CGFloat = 0.5

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testContentColumnStaysInsideWidthBoundAfterToggleResizeAndDrag() throws {
    let app = launchDemo()
    selectCategory(app, "apple", waitForRow: "1001")
    let list = app.descendants(matching: .any)["timeline.list"]
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    assertColumnWidthInsideBound(list, "initial")

    toggleSidebar(app)
    toggleSidebar(app)
    XCTAssertTrue(app.staticTexts["sidebar.category.apple"].waitForExistence(timeout: 5))
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    assertColumnWidthInsideBound(list, "after sidebar toggle x2")

    resizeWindow(app, by: -150)
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    assertColumnWidthInsideBound(list, "after window shrink")
    resizeWindow(app, by: 150)
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    assertColumnWidthInsideBound(list, "after window restore")

    dragContentDivider(app, list: list, by: -200)
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    assertColumnWidthInsideBound(list, "after divider drag toward the sidebar")
  }

  @MainActor
  func testRowPitchEqualsRowHeightFloorAfterEmptyCategorySwap() throws {
    let app = launchDemo()
    // Empty category first, then the populated one: the sibling-branch swap
    // creates a new `List` with rows already present.
    selectCategory(app, "gadgets", waitForRow: nil)
    selectCategory(app, "apple", waitForRow: "1001")
    let first = row(app, "1001")
    let second = row(app, "1002")
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    let pitch = abs(second.frame.minY - first.frame.minY)
    // The demo launch pins the medium text size (`-app_text_size 2`), so the
    // floor is the medium floor. Same source the app renders with.
    let expected = EntryRowMetrics.rowHeightFloor(scale: 1.0)
    XCTAssertEqual(pitch, expected, accuracy: Self.tolerance, "row pitch vs row-height floor")
    XCTAssertGreaterThanOrEqual(first.frame.height, EntryRowMetrics.faviconSize + 2 * EntryRowMetrics.verticalPadding)
  }

  // MARK: - Helpers

  @MainActor
  private func assertColumnWidthInsideBound(_ list: XCUIElement, _ step: String) {
    let width = list.frame.width
    XCTAssertGreaterThanOrEqual(width, Self.contentColumnMinWidth - Self.tolerance, step)
    XCTAssertLessThanOrEqual(width, Self.contentColumnMaxWidth + Self.tolerance, step)
  }

  /// Drag the window's trailing edge by `delta` points (negative = narrower).
  @MainActor
  private func resizeWindow(_ app: XCUIApplication, by delta: CGFloat) {
    let window = app.windows.firstMatch
    let frame = window.frame
    let start = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.width - 1, dy: frame.height / 2))
    let end = start.withOffset(CGVector(dx: delta, dy: 0))
    start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    Thread.sleep(forTimeInterval: 0.5)
  }

  @MainActor
  private func launchDemo() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["UITEST_IN_MEMORY_STORE"] = "1"
    app.launchEnvironment["UITEST_DEMO_MODE"] = "1"
    app.launchEnvironment["UITEST_FORCE_ONBOARDING"] = "0"
    // `NSArgumentDomain`: pins the persisted text size to medium for this
    // launch only, so the pitch expectation does not depend on the host's
    // stored preference.
    app.launchArguments += ["-app_text_size", "2"]
    app.launch()
    XCTAssertTrue(app.staticTexts["sidebar.folder.technology"].waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func selectCategory(_ app: XCUIApplication, _ label: String, waitForRow rowID: String?) {
    let category = app.staticTexts["sidebar.category.\(label)"]
    XCTAssertTrue(category.waitForExistence(timeout: 5), "category \(label)")
    category.click()
    if let rowID {
      XCTAssertTrue(row(app, rowID).waitForExistence(timeout: 10), "row \(rowID)")
    } else {
      XCTAssertTrue(app.staticTexts["No Articles"].waitForExistence(timeout: 10), "empty view")
    }
  }

  @MainActor
  private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)["entry.row.\(id)"]
  }

  @MainActor
  private func toggleSidebar(_ app: XCUIApplication) {
    let hide = app.menuBars.menuItems["Hide Sidebar"]
    let show = app.menuBars.menuItems["Show Sidebar"]
    if hide.exists {
      hide.click()
    } else if show.exists {
      show.click()
    } else {
      app.typeKey("s", modifierFlags: [.control, .command])
    }
    // The split view animates the column; wait for the layout to settle.
    _ = app.staticTexts["sidebar.folder.technology"].waitForExistence(timeout: 2)
    Thread.sleep(forTimeInterval: 0.6)
  }

  /// Drag the divider between the content column and the detail column by
  /// `delta` points (negative = toward the sidebar).
  @MainActor
  private func dragContentDivider(_ app: XCUIApplication, list: XCUIElement, by delta: CGFloat) {
    let window = app.windows.firstMatch
    let frame = list.frame
    let start = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.maxX + 0.5 - window.frame.minX, dy: frame.minY + 80 - window.frame.minY))
    let end = start.withOffset(CGVector(dx: delta, dy: 0))
    start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    Thread.sleep(forTimeInterval: 0.5)
  }
}
