import XCTest

/// A bighelp already set up that never agreed (set up before the AI data agreement existed, or a
/// device that kept an older bighelp, as App Review's can) is asked once when it opens, before it
/// shares anything, and never again after agreeing. BIGHELP_CONSENT_HOST (TEST_RUNNER_…) is an open
/// Hermes address to set up with; uninstall bighelp from the simulator first.
final class AIDataConsentGateUITests: BighelpUITestCase {
    @MainActor
    func testASetUpBighelpThatNeverAgreedIsAskedWhenItOpens() throws {
        guard let address = ProcessInfo.processInfo.environment["BIGHELP_CONSENT_HOST"] else {
            throw XCTSkip("Set BIGHELP_CONSENT_HOST to an open Hermes address")
        }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: address)
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 20), "Setup is finished")
        app.terminate()

        // The same bighelp, as if it was set up before the agreement existed.
        let reopened = makeApp()
        reopened.launchArguments += ["-test-forget-ai-data-agreement"]
        reopened.launch()
        let consent = reopened.descendants(matching: .any)["onboarding.ai-consent"].firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 20), "Asked when it opens")
        let shot = XCTAttachment(screenshot: reopened.screenshot())
        shot.name = "asked-on-open"
        shot.lifetime = .keepAlways
        add(shot)
        reopened.buttons["onboarding.ai-consent.agree"].tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 10), "Asked once")
        reopened.terminate()

        let again = makeApp()
        again.launch()
        XCTAssertTrue(again.buttons["tab.sessions"].waitForExistence(timeout: 20))
        XCTAssertFalse(again.descendants(matching: .any)["onboarding.ai-consent"].firstMatch.waitForExistence(timeout: 5),
                       "Never asked again after agreeing")
    }
}
