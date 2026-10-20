import XCTest

/// Vision Pro first run, as App Review sees it: Get Started asks once to share data with the
/// host and its AI providers (App Review 5.1.1(i), 5.1.2(i)) before any computer is connected.
/// Uninstall bighelp from the simulator first. Screenshots: see `SpatialAvatarUITests`
/// (BIGHELP_VISION_EVIDENCE).
final class VisionFirstRunConsentUITests: XCTestCase {
    @MainActor
    func testGetStartedAsksForTheAIDataAgreementFirst() throws {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "First run opens on Welcome")
        save("1-welcome", app)
        start.tap()

        let consent = app.descendants(matching: .any)["onboarding.ai-consent"].firstMatch
        XCTAssertTrue(consent.waitForExistence(timeout: 10), "Get Started asks for the AI data agreement")
        let agree = app.buttons["onboarding.ai-consent.agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5) && agree.isHittable, "Agree and continue can be selected")
        XCTAssertFalse(app.textFields["host-setup.address"].isHittable, "Connecting waits for the agreement")
        save("2-consent", app)
        agree.tap()

        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 10), "Then Connect")
        save("3-connect", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VISION_EVIDENCE"] else { return }
        let base = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let shot = base.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: shot)
        FileManager.default.createFile(atPath: base.appendingPathComponent("\(name).request").path, contents: nil)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: shot.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
