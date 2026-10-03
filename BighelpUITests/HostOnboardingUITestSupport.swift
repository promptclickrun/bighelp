import XCTest

/// Real onboarding against an open (no sign-in) isolated host from
/// Scripts/HostSignInMatrixProbe.py, for tests that run without demo fixtures.
extension BighelpUITestCase {
    @MainActor func onboardOpenHost(_ app: XCUIApplication, address: String) throws {
        let start = app.buttons["onboarding.get-started"]
        let field = app.textFields["host-setup.address"]
        // The welcome is remembered past one test's run, so a later test can open on the address step.
        if !field.waitForExistence(timeout: 5) {
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            start.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address)
        // During onboarding the button reports the screen's identifier.
        let connect = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch
        let next = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND (label == %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], "Start chatting", "Let")).firstMatch
        // An open host needs no sign-in: one Continue connects, over plain HTTP on a private address.
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        connect.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
    }
}
