//
//  FeederUITests.swift
//  FeederUITests
//

import XCTest

final class FeederUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
  }

  @MainActor
  func testOnboardingFormEnablesConnectButton() throws {
    let app = makeApp(forceOnboarding: true)
    app.launch()

    let email = app.textFields["onboarding.email"]
    let password = app.secureTextFields["onboarding.password"]
    let connect = app.buttons["onboarding.connect"]

    XCTAssertTrue(email.waitForExistence(timeout: 5))
    XCTAssertTrue(password.exists)
    XCTAssertTrue(connect.exists)
    XCTAssertFalse(connect.isEnabled)

    email.click()
    email.typeText("ui-test@example.com")
    password.click()
    password.typeText("test-password")

    XCTAssertTrue(connect.isEnabled)
  }

  @MainActor
  func testDemoTimelineInteractionSmoke() throws {
    let app = makeApp()
    app.launch()

    // Wait for sidebar folder to appear (demo data seeded)
    let technologyFolder = app.staticTexts["sidebar.folder.technology"]
    XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10))
    technologyFolder.click()

    // Wait for a known demo article to appear in the timeline (via accessibility identifier)
    let articleRow = app.descendants(matching: .any)["entry.row.1001"]
    XCTAssertTrue(articleRow.waitForExistence(timeout: 10))
    articleRow.click()

    // Keyboard navigation
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.upArrow, modifierFlags: [])

    // Sync button should exist
    let syncButton = app.buttons["toolbar.sync"]
    XCTAssertTrue(syncButton.exists)

    // Detail view should be visible after selecting an article
    let detailView = app.descendants(matching: .any)["entry.detail"]
    XCTAssertTrue(detailView.waitForExistence(timeout: 5))
  }

  @MainActor
  func testArticleFilterSwitchesAndPreservesEntry() throws {
    let app = makeApp()
    app.launch()

    // Select the technology folder
    let technologyFolder = app.staticTexts["sidebar.folder.technology"]
    XCTAssertTrue(technologyFolder.waitForExistence(timeout: 10))
    technologyFolder.click()

    // Verify filter picker exists with both segments
    let filterPicker = app.descendants(matching: .any)["article.filter"]
    XCTAssertTrue(filterPicker.waitForExistence(timeout: 5))

    // Default tab is Unread — verify a known unread article is visible
    let unreadArticle = app.descendants(matching: .any)["entry.row.1001"]
    XCTAssertTrue(unreadArticle.waitForExistence(timeout: 5))

    // Select the article — it stays in the list while still unread (deferred
    // read marking via pendingReadIDs).
    unreadArticle.click()
    XCTAssertTrue(unreadArticle.waitForExistence(timeout: 2))

    // Switch to Read tab. macOS segmented controls expose segments as radioButtons.
    // `.onChange(of: articleFilter)` in ContentView flushes pendingReadIDs on tab
    // change, so the just-clicked entry becomes persistently read.
    let readTab = app.radioButtons["Read"]
    XCTAssertTrue(readTab.waitForExistence(timeout: 5))
    readTab.click()

    // A pre-seeded read entry should be visible (demo seeds every 3rd article
    // read: 1003, 1006, 1009, 1012).
    let preSeededRead = app.descendants(matching: .any)["entry.row.1003"]
    XCTAssertTrue(preSeededRead.waitForExistence(timeout: 5))

    // Switch back to Unread tab — other unread articles still appear.
    // Two successive tab switches + the background section refetch occasionally
    // take longer than the 5 s default, so wait up to 10 s here.
    let unreadTab = app.radioButtons["Unread"]
    unreadTab.click()

    let anotherUnread = app.descendants(matching: .any)["entry.row.1002"]
    XCTAssertTrue(anotherUnread.waitForExistence(timeout: 10))
  }

  /// Click-focus fix, hardest starting state (Step-0 assumptions A + B):
  /// with first responder INSIDE the article WKWebView, a click on a sidebar
  /// row must both commit the selection (A: the List row click invokes the
  /// selection-binding setter even when focus is elsewhere) and reclaim
  /// keyboard focus from the AppKit view (B: the binding's `panelFocus`
  /// write wins over the web view) — so arrow keys act on the sidebar
  /// immediately, no Tab required.
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

  /// Click-focus fix, article list: clicking a row must move keyboard focus
  /// to the list so arrow-down selects the next row immediately — proven by
  /// the detail pane switching to the next article, no Tab pressed.
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

  /// Bare-key fix: with first responder inside the article web view, typing
  /// "r" must toggle the view mode (web → reader) via
  /// `BareKeyForwardingWebView` — proven by the detail toolbar button
  /// flipping its label from "Reader Mode" to "Web Mode". No UI test for B
  /// (it opens the system browser).
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
  private func makeApp(forceOnboarding: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["UITEST_IN_MEMORY_STORE"] = "1"
    app.launchEnvironment["UITEST_DEMO_MODE"] = forceOnboarding ? "0" : "1"
    app.launchEnvironment["UITEST_FORCE_ONBOARDING"] = forceOnboarding ? "1" : "0"
    return app
  }
}
