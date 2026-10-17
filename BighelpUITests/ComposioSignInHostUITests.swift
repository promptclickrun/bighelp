import XCTest

/// Settings › Apps › Composio Apps › Sign in to Composio, the real way (no demo data): Composio's page
/// opens in the system sign-in sheet. Set BIGHELP_COMPOSIO_HOST (TEST_RUNNER_…) to an open Hermes
/// host's address; skipped without it. Uninstall bighelp from the simulator first.
final class ComposioSignInHostUITests: BighelpUITestCase {
    @MainActor
    func testSignInToComposioOpensComposiosPage() throws {
        guard let address = ProcessInfo.processInfo.environment["BIGHELP_COMPOSIO_HOST"] else {
            throw XCTSkip("Set BIGHELP_COMPOSIO_HOST to an open Hermes host's address")
        }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: address)
        openSettings(in: app)
        settingsRow("settings.apps", in: app).tap()
        let composio = app.buttons["apps.composio"]
        XCTAssertTrue(composio.waitForExistence(timeout: 10))
        composio.tap()
        let signIn = app.buttons["composio.sign-in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        signIn.tap()
        // iOS asks before Composio's page opens; the app must still be running behind it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let continueButton = springboard.alerts.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 20), "The system sign-in sheet asks to open Composio")
        XCTAssertEqual(app.state, .runningForeground, "bighelp didn't crash")
        springboard.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "Cancelling returns to Sign in to Composio")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
