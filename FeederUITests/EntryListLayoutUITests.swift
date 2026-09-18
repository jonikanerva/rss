import XCTest

/// Deterministic layout invariant for the article list, one trial.
///
/// After the empty-category -> populated-category swap, the row pitch
/// equals the row-height floor: the floor is the row height, so a lost row
/// re-measure in the `List` bridge has nothing left to clip.
///
/// The content column has no width bound, so there is no width invariant to
/// pin here.
final class EntryListLayoutUITests: XCTestCase {
  /// Tolerance for point values read through the accessibility frames.
  private static let tolerance: CGFloat = 0.5

  override func setUpWithError() throws {
    continueAfterFailure = false
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
}
