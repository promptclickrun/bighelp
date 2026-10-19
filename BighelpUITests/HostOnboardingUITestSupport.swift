import XCTest

/// Real onboarding against an open (no sign-in) isolated host from
/// Scripts/HostSignInMatrixProbe.py, for tests that run without demo fixtures.
extension BighelpUITestCase {
    /// The very first setup asks once to share data with AI providers; agrees when it does.
    @MainActor func agreeToAIDataIfAsked(_ app: XCUIApplication) {
        let agree = app.buttons["onboarding.ai-consent.agree"]
        if agree.waitForExistence(timeout: 3) { agree.tap() }
    }

    @MainActor func onboardOpenHost(_ app: XCUIApplication, address: String) throws {
        let start = app.buttons["onboarding.get-started"]
        let field = app.textFields["host-setup.address"]
        // The welcome is remembered past one test's run, so a later test can open on the address step.
        if !field.waitForExistence(timeout: 5) {
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            start.tap()
            agreeToAIDataIfAsked(app)
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address)
        // During onboarding the button reports the screen's identifier.
        let connect = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch
        // An open host needs no sign-in: one Continue connects, over plain HTTP on a private address.
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        connect.tap()
        XCTAssertTrue(continueAfterConnecting(app), "Connected")
    }

    /// Connected: the step says so, and its button goes on through the plugin and mode steps. The
    /// button reads Continue in first setup, like Connect's, so the step's own line tells them apart.
    @MainActor @discardableResult
    func continueAfterConnecting(_ app: XCUIApplication, timeout: TimeInterval = 45) -> Bool {
        guard app.staticTexts["Your agents are ready to chat."].waitForExistence(timeout: timeout) else { return false }
        let next = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND (label IN %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], ["Start chatting", "Continue"], "Let")).firstMatch
        guard next.waitForExistence(timeout: 10) else { return false }
        next.tap()
        finishFirstSetup(app)
        return true
    }

    /// After Connect: skips the optional plugin (and notifications) and chooses Sessions, the app as it
    /// comes, which these tests expect.
    /// BIGHELP_FIRST_SETUP_EVIDENCE (TEST_RUNNER_…) saves the plugin step as the host shows it.
    @MainActor func finishFirstSetup(_ app: XCUIApplication) {
        let skip = app.buttons["onboarding.skip"]
        if skip.waitForExistence(timeout: 15) {
            if let folder = ProcessInfo.processInfo.environment["BIGHELP_FIRST_SETUP_EVIDENCE"] {
                // The step checks the computer for the plugin first.
                sleep(6)
                try? XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("first-setup-plugin.png"))
            }
            skip.tap()
        }
        if app.buttons["onboarding.notifications.enable"].waitForExistence(timeout: 2) { skip.tap() }
        let sessions = app.buttons["onboarding.mode.sessions"]
        guard sessions.waitForExistence(timeout: 10) else { return }
        app.buttons["onboarding.mode.bots"].swipeLeft()
        sessions.tap()
        let use = app.buttons["onboarding.mode.preview.use"]
        if use.waitForExistence(timeout: 5) { use.tap() }
    }
}
