import XCTest

/// A stopped notification setup shows a code people can send us, and Copy Details (#443).
/// Demo data with a made-up computer (`-test-host-setup connected`) and a failure forced by
/// `-test-notification-failure`.
@MainActor
final class NotificationErrorCodeUITests: BighelpUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testHostSetupShowsTheCodeAndCopiesDetails() {
        for appearance in ["light", "dark"] {
            let app = openHostSetup(failure: "NS-102", appearance: appearance)
            let code = app.staticTexts["host-setup.notification-failure.code"]
            XCTAssertTrue(code.waitForExistence(timeout: 10), "The code shows under the message")
            XCTAssertEqual(code.label, "Code NS-102")
            let status = app.descendants(matching: .any)["host-setup.notification-status"].firstMatch
            XCTAssertTrue(status.label.contains("can't reach its notification service"), status.label)
            XCTAssertTrue(app.buttons["host-setup.enable-notifications"].exists, "Trying again can help, so it's offered")
            capture("Host setup NS-102 \(appearance)")
            let copy = app.buttons["host-setup.notification-failure.copy"]
            XCTAssertTrue(copy.isHittable)
            copy.tap()
            XCTAssertTrue(copy.label.contains("Copied"), copy.label)
            app.terminate()
        }
    }

    func testAFailureRetryingCannotFixOffersNoCheckAgain() {
        let app = openHostSetup(failure: "NS-420", appearance: "light")
        let code = app.staticTexts["host-setup.notification-failure.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertEqual(code.label, "Code NS-420")
        XCTAssertFalse(app.buttons["host-setup.enable-notifications"].exists, "Checking again can't fix it")
        XCTAssertTrue(app.buttons["host-setup.notifications-set-up-again"].exists, "Set Up Again can")
        capture("Host setup NS-420 light")
    }

    func testProviderDetailsShowTheLastProblem() {
        openHostSetup(failure: "NS-113", appearance: "dark").terminate()
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.notifications", in: app).tap()
        let page = app.descendants(matching: .any)["settings.notifications"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let details = app.descendants(matching: .any)["settings.notifications.details"].firstMatch
        for _ in 0..<10 where !(details.exists && details.isHittable) { page.swipeUp() }
        details.tap()
        // The disclosure's identifier covers its rows, so find the code by what it says.
        let code = app.staticTexts.matching(NSPredicate(format: "label == %@", "Code NS-113")).firstMatch
        for _ in 0..<6 where !(code.exists && code.isHittable) { page.swipeUp() }
        XCTAssertTrue(code.waitForExistence(timeout: 5), "Provider details keep the last problem")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last setup problem")).firstMatch.exists)
        capture("Provider details NS-113 dark")
    }

    private func openHostSetup(failure: String, appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-host-setup", "connected",
                               "-test-notification-failure", failure, "-loopdy.demo.appearance", appearance]
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "☰ menu")
        menu.tap()
        let hosts = app.buttons["menu.hosts"]
        XCTAssertTrue(hosts.waitForExistence(timeout: 5))
        hosts.tap()
        let add = app.buttons["menu.host.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
