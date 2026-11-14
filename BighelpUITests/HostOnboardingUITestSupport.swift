import XCTest

/// Real onboarding against an open (no sign-in) isolated host from
/// Scripts/HostSignInMatrixProbe.py, for tests that run without demo fixtures.
extension BighelpUITestCase {
    /// The very first setup asks once to share data with AI providers; agrees when it does.
    @MainActor func agreeToAIDataIfAsked(_ app: XCUIApplication) {
        let agree = app.buttons["onboarding.ai-consent.agree"]
        guard agree.waitForExistence(timeout: 3) else { return }
        agree.tap()
        // The sheet closes with an animation. A tap on a field under it before it's gone gives no
        // keyboard focus, and the typing that follows fails.
        _ = agree.waitForNonExistence(timeout: 5)
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
        // A run that opens on the address step (the welcome was done in an earlier run) can still be
        // asked to agree, over the step: the field takes no typing until that sheet is answered.
        agreeToAIDataIfAsked(app)
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

    /// Connected: the step says so, and its button goes on through the plugin and home steps. The
    /// button reads Continue in first setup, like Connect's, so the step's own line tells them apart.
    @MainActor @discardableResult
    func continueAfterConnecting(_ app: XCUIApplication, timeout: TimeInterval = 45) -> Bool {
        guard app.staticTexts["Your bots are ready to chat."].waitForExistence(timeout: timeout) else { return false }
        let next = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND (label IN %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], ["Start chatting", "Continue"], "Let")).firstMatch
        guard next.waitForExistence(timeout: 10) else { return false }
        next.tap()
        finishFirstSetup(app)
        return true
    }

    /// After Connect: skips the optional plugin (and notifications) and answers "How do you want to
    /// start?" with Chats, the list these tests expect.
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
        let chats = app.buttons["onboarding.mode.chats"]
        guard chats.waitForExistence(timeout: 10) else { return }
        chats.tap()
        let next = app.buttons["onboarding.mode.continue"]
        if next.waitForExistence(timeout: 5) { next.tap() }
    }
}
