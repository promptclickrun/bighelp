import XCTest

@MainActor
final class FirstRunOnboardingUITests: BighelpUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDown() async throws { await MainActor.run { XCUIDevice.shared.orientation = .portrait } }

    func testWelcomeAppearanceConnectionAndBackNavigation() {
        let app = launchFresh()
        XCTAssertTrue(app.buttons["onboarding.get-started"].waitForExistence(timeout: 15))
        capture("Welcome portrait")
        app.buttons["onboarding.customize-appearance"].tap()
        let next = app.buttons["onboarding.appearance.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        capture("Appearance portrait")
        next.tap()
        // Asked once, before connecting to anything.
        let agree = app.buttons["onboarding.ai-consent.agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5))
        capture("AI data agreement")
        agree.tap()
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.back"].isHittable)
        app.textFields["host-setup.address"].tap()
        app.textFields["host-setup.address"].typeText("localhost")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.textFields["host-setup.address"].frame.maxY,
                                 app.keyboards.firstMatch.frame.minY)
        capture("Connection with keyboard")
        app.buttons["onboarding.back"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        XCTAssertFalse(agree.waitForExistence(timeout: 2), "Agreed once: never asked again.")
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["host-setup.address"].value as? String, "localhost")
    }

    func testLandscapeFlowKeepsContinueAndHostControlsReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchFresh()
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(start.isHittable)
        capture("Welcome landscape")
        let customize = app.buttons["onboarding.customize-appearance"]
        XCTAssertTrue(customize.isHittable)
        customize.tap()
        let next = app.buttons["onboarding.appearance.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.isHittable)
        capture("Appearance landscape")
        next.tap()
        agreeToAIDataIfAsked(app)
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
        capture("Connection landscape")
    }

    func testThemeAndAppearancePersistAcrossRelaunch() {
        let app = launchFresh()
        XCTAssertTrue(app.buttons["onboarding.get-started"].waitForExistence(timeout: 15))
        app.buttons["onboarding.customize-appearance"].tap()
        let dark = app.segmentedControls["settings.appearance"].buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        // The same bubble colors as Settings › Appearance.
        let ocean = app.buttons["appearance.bubble.ocean"]
        for _ in 0..<4 where !ocean.isHittable { app.swipeUp() }
        ocean.tap()
        XCTAssertTrue(ocean.isSelected)
        capture("Chosen bubble color in dark appearance")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.appearance.continue"].waitForExistence(timeout: 15))
        let restored = app.buttons["appearance.bubble.ocean"]
        for _ in 0..<4 where !restored.isHittable { app.swipeUp() }
        XCTAssertTrue(restored.isSelected)
        XCTAssertTrue(app.segmentedControls["settings.appearance"].buttons["Dark"].isSelected)
    }

    /// The agreement to share data with AI providers is asked the very first time only:
    /// a relaunch and another Get Started don't ask again.
    func testAIDataAgreementIsAskedOnlyTheFirstTime() {
        let app = launchFresh()
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let agree = app.buttons["onboarding.ai-consent.agree"]
        XCTAssertTrue(agree.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.ai-consent.privacy"].exists, "It links the privacy policy.")
        agree.tap()
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        let back = app.buttons["onboarding.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertFalse(agree.waitForExistence(timeout: 2), "Never asked again.")
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
    }

    func testConfiguredWorkspaceSkipsFirstRun() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.get-started"].exists)
    }

    /// After Connect: the plugin and notifications can be skipped, the mode can't, and the
    /// mode chosen is the home onboarding ends on.
    func testOptionalStepsSkipAndTheChosenModeOpens() {
        let app = launchAfterConnect(at: 3)
        XCTAssertTrue(app.buttons["onboarding.plugin.install"].waitForExistence(timeout: 15))
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.isHittable, "The plugin is optional.")
        capture("Plugin")
        skip.tap()

        XCTAssertTrue(app.staticTexts["onboarding.mode.later"].waitForExistence(timeout: 5))
        XCTAssertFalse(skip.exists, "Choosing a mode can't be skipped.")
        XCTAssertTrue(app.buttons["onboarding.mode.bots"].exists)
        capture("Choose your mode")
        app.buttons["onboarding.mode.bots"].swipeLeft()
        app.buttons["onboarding.mode.sessions"].swipeLeft()
        let code = app.buttons["onboarding.mode.code"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        let use = app.buttons["onboarding.mode.preview.use"]
        XCTAssertTrue(use.waitForExistence(timeout: 5), "A card shows its mode's preview.")
        capture("Code preview")
        use.tap()
        XCTAssertTrue(app.descendants(matching: .any)["code.screen"].firstMatch.waitForExistence(timeout: 10),
                      "Code opens as the home.")
    }

    func testNotificationsCanBeSkipped() {
        let app = launchAfterConnect(at: 4)
        XCTAssertTrue(app.buttons["onboarding.notifications.enable"].waitForExistence(timeout: 15))
        capture("Notifications")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.staticTexts["onboarding.mode.later"].waitForExistence(timeout: 5))
    }

    private func launchAfterConnect(at step: Int) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-force-signed-out-onboarding",
                               "-bighelp.onboarding.after-connect", "YES",
                               "-loopdy.onboarding.first-run-v1.step", "\(step)"]
        app.launch()
        return app
    }

    private func launchFresh() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts", "-force-signed-out-onboarding"]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
