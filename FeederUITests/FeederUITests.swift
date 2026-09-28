import XCTest

final class FeederUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// The owner-run focus check: one launch, then these checks in order: the
  /// VoiceOver label of the detail pane, a row click and then an arrow key,
  /// bare R inside the web view, and a sidebar click from the web view. Of the
  /// checks, only the last changes the sidebar selection, which saves the
  /// opened articles as read.
  @MainActor
  func testFocusFlows() throws {
    let app = makeHeadlessApp()
    app.launch()

    XCTContext.runActivity(named: "Launch") { _ in
      let technologyFolder = app.staticTexts["sidebar.folder.technology"]
      XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10), "Launch: the Technology folder appears")
      technologyFolder.click()
    }

    XCTContext.runActivity(named: "VoiceOver label") { _ in
      let firstRow = app.descendants(matching: .any)["entry.row.1001"]
      XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "VoiceOver label: row 1001 appears")
      firstRow.click()
      XCTAssertTrue(
        articleDetail(titled: "Sample Tech Story 1", in: app).waitForExistence(timeout: 10),
        "VoiceOver label: the detail pane has the label of story 1")
    }

    XCTContext.runActivity(named: "Row click, then arrow") { _ in
      XCTAssertTrue(
        articleDetail(titled: "Sample Tech Story 1", in: app).waitForExistence(timeout: 5),
        "Row click, then arrow: the detail pane shows story 1")
      app.typeKey(.downArrow, modifierFlags: [])
      // The row click of the check before must move keyboard focus from the
      // sidebar to the list, so the arrow key selects the next row at once,
      // which the detail pane switching proves.
      XCTAssertTrue(
        articleDetail(titled: "Sample Tech Story 2", in: app).waitForExistence(timeout: 10),
        "Row click, then arrow: the detail pane shows story 2")
    }

    // The open-in-browser key has no UI test, because it leaves the app.
    XCTContext.runActivity(named: "Bare R") { _ in
      // The toggle button names the other mode: "Reader Mode" shows in web mode.
      XCTAssertTrue(app.buttons["Reader Mode"].waitForExistence(timeout: 10), "Bare R: the web mode shows")
      clickInsideWebView(of: app, check: "Bare R")
      app.typeText("r")
      // With first responder inside the article web view, the reader-mode key
      // must still toggle the view mode, which the toolbar button's label
      // proves.
      XCTAssertTrue(app.buttons["Web Mode"].waitForExistence(timeout: 10), "Bare R: the reader mode shows")
    }

    XCTContext.runActivity(named: "Sidebar click") { _ in
      let webModeButton = app.buttons["Web Mode"].firstMatch
      XCTAssertTrue(webModeButton.waitForExistence(timeout: 5), "Sidebar click: the reader mode shows")
      // Reader mode has no web view: the toolbar button returns to web mode
      // and keeps the selected article.
      webModeButton.click()
      XCTAssertTrue(app.buttons["Reader Mode"].waitForExistence(timeout: 10), "Sidebar click: the web mode shows")
      clickInsideWebView(of: app, check: "Sidebar click")
      // With first responder inside the web view, a click on a sidebar row
      // must both commit the selection and reclaim keyboard focus from the
      // AppKit view, so the arrow keys act on the sidebar at once and no Tab
      // is needed.
      let appleCategory = app.staticTexts["sidebar.category.apple"]
      XCTAssertTrue(appleCategory.waitForExistence(timeout: 5), "Sidebar click: the Apple category appears")
      appleCategory.click()
      app.typeKey(.downArrow, modifierFlags: [])
      // Arrow-down from Apple lands on the root category World News, whose
      // timeline holds only the seeded world entry. The entry appears only
      // when both hold: the click committed the selection to Apple, and focus
      // moved to the sidebar, so the arrow key acted there.
      XCTAssertTrue(
        app.descendants(matching: .any)["entry.row.2001"].waitForExistence(timeout: 10),
        "Sidebar click: the World News entry appears")
    }
  }

  @MainActor
  func testVercelSettingsKeyboardSmoke() throws {
    let app = makeHeadlessApp()
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
  private func articleDetail(titled title: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'entry.detail' AND label == %@", "Article: \(title)")
    ).firstMatch
  }

  /// Clicks the article web view, so first responder moves inside it. The
  /// seeded article body has no links, so the click cannot navigate, and the
  /// offset stays below the header.
  @MainActor
  private func clickInsideWebView(of app: XCUIApplication, check: String) {
    let webView = app.webViews.firstMatch
    XCTAssertTrue(webView.waitForExistence(timeout: 10), "\(check): the web view appears")
    webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).click()
  }

  @MainActor
  private func nativeText(_ text: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
  }

  /// The owner's `UserDefaults` reach this launch. The arguments override two
  /// values for this launch only: every sidebar folder is expanded, and the
  /// bootstrap adds no default categories to the in-memory store.
  @MainActor
  private func makeHeadlessApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["FEEDER_HEADLESS"] = "1"
    app.launchArguments += ["-sidebar.collapsedFolders", "[]", "-feeder.defaultsSeeded", "YES"]
    return app
  }
}
