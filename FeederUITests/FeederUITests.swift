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

        let technologyCategory = app.staticTexts["sidebar.category.technology"]
        XCTAssertTrue(technologyCategory.waitForExistence(timeout: 5))
        technologyCategory.click()

        let timelineList = app.descendants(matching: .any)["timeline.list"]
        XCTAssertTrue(timelineList.waitForExistence(timeout: 5))
        timelineList.click()

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])

        let syncButton = app.buttons["toolbar.sync"]
        XCTAssertTrue(syncButton.exists)
        syncButton.click()

        let detailView = app.otherElements["entry.detail"]
        XCTAssertTrue(detailView.waitForExistence(timeout: 5))

        timelineList.swipeUp()
        timelineList.swipeDown()
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
