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

        // Wait for sidebar category to appear (demo data seeded)
        let technologyCategory = app.staticTexts["sidebar.category.technology"]
        XCTAssertTrue(technologyCategory.waitForExistence(timeout: 10))
        technologyCategory.click()

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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            makeApp().launch()
        }
    }

    private func makeApp(forceOnboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_IN_MEMORY_STORE"] = "1"
        app.launchEnvironment["UITEST_DEMO_MODE"] = forceOnboarding ? "0" : "1"
        app.launchEnvironment["UITEST_FORCE_ONBOARDING"] = forceOnboarding ? "1" : "0"
        return app
    }
}
