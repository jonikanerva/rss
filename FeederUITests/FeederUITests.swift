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

  @MainActor
  private func makeApp(forceOnboarding: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["UITEST_IN_MEMORY_STORE"] = "1"
    app.launchEnvironment["UITEST_DEMO_MODE"] = forceOnboarding ? "0" : "1"
    app.launchEnvironment["UITEST_FORCE_ONBOARDING"] = forceOnboarding ? "1" : "0"
    return app
  }
}
