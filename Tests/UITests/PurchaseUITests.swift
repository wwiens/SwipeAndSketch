import XCTest

@MainActor final class PurchaseUITests: XCTestCase {
    private func launch(_ state: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-solid", "--ui-testing-access", "--ui-testing-purchases", state]
        app.launch()
        return app
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
    }

    func testOfferDisclosesPriceAndExplicitTrialWithoutActivatingIt() {
        let app = launch("--access-not-started")
        let start = app.buttons["purchase.startTrial"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let terms = app.staticTexts["purchase.terms"]
        XCTAssertTrue(terms.label.contains("$19.99"))
        XCTAssertTrue(terms.label.contains("No subscription or automatic charge"))
        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(app.buttons["purchase.buy"].label.contains("$19.99"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "14-day trial offer"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["purchase.done"].tap()
        XCTAssertTrue(app.buttons["workspace.unlock"].waitForExistence(timeout: 5), "Viewing the offer must not start the trial")
    }

    func testExpiredTrialCanDismissOfferInspectNotesAndExport() {
        let app = launch("--access-expired")
        let access = app.staticTexts["purchase.fileAccess"]
        XCTAssertTrue(access.waitForExistence(timeout: 15))
        XCTAssertTrue(access.label.contains("export projects at full quality"))
        XCTAssertFalse(app.buttons["purchase.startTrial"].exists)
        let continueViewing = app.buttons["purchase.continue"]
        scrollTo(continueViewing, in: app)
        continueViewing.tap()
        XCTAssertTrue(app.buttons["workspace.unlock"].waitForExistence(timeout: 5))
        app.buttons["notes.toggle"].tap()
        XCTAssertTrue(app.textViews["notes.content"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["notes.editor"].exists)
        app.buttons["notes.close"].tap()
        app.buttons["Project menu"].tap()
        let export = app.buttons["project.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertTrue(export.isEnabled)
    }

    func testActiveTrialShowsItsEndAndPurchasedStateHasNoSalesPrompt() {
        let app = launch("--access-trial")
        XCTAssertTrue(app.staticTexts["purchase.trialEnd"].waitForExistence(timeout: 15))
        app.buttons["purchase.done"].tap()
        XCTAssertFalse(app.buttons["workspace.unlock"].exists)
        app.terminate()
        let purchased = launch("--access-purchased")
        XCTAssertTrue(purchased.staticTexts["Swipe & Sketch purchased"].waitForExistence(timeout: 15))
        XCTAssertFalse(purchased.buttons["purchase.startTrial"].exists)
        XCTAssertFalse(purchased.buttons["purchase.buy"].exists)
    }
}
