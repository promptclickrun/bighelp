import XCTest

/// Settings › Permissions › Device access › Share usage and diagnostics, on the demo data. Demo mode
/// sends nothing; its stand-in host only records what it would have been told.
final class TelemetrySettingsUITests: BighelpUITestCase {
    @MainActor
    func testSharingIsOnByDefaultInLight() throws {
        try sharingIsOnByDefault(appearance: "light")
    }

    @MainActor
    func testSharingIsOnByDefaultInDark() throws {
        try sharingIsOnByDefault(appearance: "dark")
    }

    @MainActor
    private func sharingIsOnByDefault(appearance: String) throws {
        let app = launch(appearance: appearance)
        let toggle = openSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "1", "On until the person turns it off")
        XCTAssertTrue(app.staticTexts["Share usage and diagnostics"].exists)
        XCTAssertTrue(app.staticTexts["Anonymous counts and crash reports. Never your messages, files or names."].exists)
        capture("telemetry-switch-on-\(appearance)", in: app)
    }

    @MainActor
    func testTurningItOffAndBackOnKeepsTheChoice() throws {
        let app = launch(appearance: "light")
        var toggle = openSwitch(in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        capture("telemetry-switch-off-light", in: app)
        XCTAssertEqual(app.alerts.count, 0, "No iOS permission is asked for")

        // The choice is kept when Settings is closed and opened again.
        closeSettings(in: app)
        toggle = openSwitch(in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testItIsNotOnlyForNerdMode() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        let toggle = openSwitch(in: app)
        XCTAssertTrue(toggle.exists)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func openSwitch(in app: XCUIApplication) -> XCUIElement {
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
        let target = app.switches["settings.telemetry.toggle"].firstMatch
        // Scroll until the switch and the line under it sit well inside the screen, not on its edge.
        let bottom = app.windows.firstMatch.frame.maxY
        for _ in 0..<12 where !target.exists || !target.isHittable || target.frame.maxY > bottom - 220 { form.swipeUp() }
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        return target
    }

    /// Kept with the run; also saved to `BIGHELP_SCREENSHOT_DIR` when it's set.
    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
