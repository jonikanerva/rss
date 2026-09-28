import XCTest

final class FeederUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
  }

  /// The hardest starting state for focus-follows-click: with first responder
  /// inside the article web view, a click on a sidebar row must both commit the
  /// selection and reclaim keyboard focus from the AppKit view, so the arrow
  /// keys act on the sidebar at once and no Tab is needed.
  @MainActor
  func testClickReclaimsFocusFromWebViewForSidebarArrows() throws {
    let app = makeApp()
    app.launch()

    // Open an article so the detail pane hosts the web view.
    let technologyFolder = app.staticTexts["sidebar.folder.technology"]
    XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10))
    technologyFolder.click()
    let articleRow = app.descendants(matching: .any)["entry.row.1001"]
    XCTAssertTrue(articleRow.waitForExistence(timeout: 10))
    articleRow.click()

    // Put first responder inside the web view. The demo article body has no
    // links, so the click cannot navigate; the offset stays below the header.
    let webView = app.webViews.firstMatch
    XCTAssertTrue(webView.waitForExistence(timeout: 10))
    webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()

    // Click a sidebar category, then press arrow-down without Tab.
    let appleCategory = app.staticTexts["sidebar.category.apple"]
    XCTAssertTrue(appleCategory.waitForExistence(timeout: 5))
    appleCategory.click()
    app.typeKey(.downArrow, modifierFlags: [])

    // Arrow-down from "Apple" lands on the root category "World News", whose
    // timeline contains only the seeded world entry. It appears ONLY when
    // both hold: the click committed the selection to "apple" AND focus
    // moved to the sidebar so the arrow key acted there.
    let worldEntry = app.descendants(matching: .any)["entry.row.2001"]
    XCTAssertTrue(worldEntry.waitForExistence(timeout: 10))
  }

  /// Clicking a row in the article list must move keyboard focus to that list,
  /// so arrow-down selects the next row at once, which the detail pane switching
  /// proves.
  @MainActor
  func testClickArticleRowThenArrowSelectsNextRow() throws {
    let app = makeApp()
    app.launch()

    let technologyFolder = app.staticTexts["sidebar.folder.technology"]
    XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10))
    technologyFolder.click()

    let firstRow = app.descendants(matching: .any)["entry.row.1001"]
    XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
    firstRow.click()

    let detail = app.descendants(matching: .any)["entry.detail"]
    XCTAssertTrue(detail.waitForExistence(timeout: 5))

    app.typeKey(.downArrow, modifierFlags: [])

    // Row 1002 is the next unread row after 1001 (1003 is seeded read).
    let secondArticleDetail = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'entry.detail' AND label == 'Article: Sample Tech Story 2'")
    ).firstMatch
    XCTAssertTrue(secondArticleDetail.waitForExistence(timeout: 10))
  }

  /// With first responder inside the article web view, the reader-mode key must
  /// still toggle the view mode, which the detail toolbar button's label proves.
  /// The open-in-browser key has no UI test, because it leaves the app.
  @MainActor
  func testBareKeyRInsideWebViewTogglesViewMode() throws {
    let app = makeApp()
    app.launch()

    let technologyFolder = app.staticTexts["sidebar.folder.technology"]
    XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10))
    technologyFolder.click()
    let articleRow = app.descendants(matching: .any)["entry.row.1001"]
    XCTAssertTrue(articleRow.waitForExistence(timeout: 10))
    articleRow.click()

    // Web mode is the default — the toggle button offers "Reader Mode".
    XCTAssertTrue(app.buttons["Reader Mode"].waitForExistence(timeout: 10))

    // Click into the web content so the WKWebView is first responder (the
    // demo article body has no links; the offset stays below the header).
    let webView = app.webViews.firstMatch
    XCTAssertTrue(webView.waitForExistence(timeout: 10))
    webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()

    app.typeText("r")

    XCTAssertTrue(app.buttons["Web Mode"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testVercelSettingsKeyboardSmoke() throws {
    let app = makeApp()
    app.launchEnvironment["FEEDER_HEADLESS"] = "1"
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.buttons["toolbar.sync"].waitForExistence(timeout: 10))
    app.typeKey(",", modifierFlags: .command)
    let tab = app.buttons["Classification"]
    XCTAssertTrue(tab.exists || tab.waitForExistence(timeout: 5), app.debugDescription)
    tab.click()
    let provider = app.radioButtons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "classification.provider.vercel")).firstMatch
    XCTAssertTrue(provider.exists || provider.waitForExistence(timeout: 5), app.debugDescription)
    provider.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
    XCTAssertTrue(provider.isSelected)
    XCTAssertTrue(
      nativeText("JEV (Typesafe)", in: app).exists || nativeText("JEV (Typesafe)", in: app).waitForExistence(timeout: 5),
      app.debugDescription)
    let edit = app.buttons["classification.key.edit"]
    edit.click()
    let field = app.secureTextFields["classification.key.field"]
    XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["classification.key.save"].isEnabled)
    field.click()
    field.typeText("fake-ui-key")
    XCTAssertTrue(app.buttons["classification.key.save"].isEnabled)
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.buttons["Reclassify"].exists || app.buttons["Reclassify"].waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(app.buttons["Reclassify"].exists)
    XCTAssertFalse(field.exists)
    XCTAssertTrue(nativeText("API key is saved", in: app).exists || nativeText("API key is saved", in: app).waitForExistence(timeout: 5))
    edit.click()
    XCTAssertTrue(field.exists || field.waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(app.buttons["Reclassify"].exists)
    XCTAssertFalse(field.exists)
    XCTAssertTrue(nativeText("API key is saved", in: app).exists || nativeText("API key is saved", in: app).waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Reclassify"].exists)
  }

  @MainActor
  private func nativeText(_ text: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
  }

  @MainActor
  private func makeApp() -> XCUIApplication {
    let app = XCUIApplication()
    // Without demo mode the in-memory launch finds no stored account and shows
    // onboarding.
    app.launchEnvironment["UITEST_IN_MEMORY_STORE"] = "1"
    app.launchEnvironment["UITEST_DEMO_MODE"] = "1"
    return app
  }
}
