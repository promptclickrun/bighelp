import XCTest

final class DeviceToolPermissionsUITests: BighelpUITestCase {
    @MainActor
    func testIndependentPhoneToolsStartOffInPermissions() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
            "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
            "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()

        for capability in ["health", "calendar", "reminders", "location"] {
            let toggle = deviceToolSwitch(capability, in: app)
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
            if capability == "location" {
                // Demo mode's made-up place can be shared; it never asks iOS for a real one.
                XCTAssertTrue(toggle.isEnabled)
            } else {
                // Demo fixtures must not prompt for real data: these report unavailable.
                expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: toggle)
                waitForExpectations(timeout: 10)
            }
            if capability == "calendar" || capability == "reminders" {
                XCTAssertTrue(app.staticTexts[capability == "calendar"
                    ? "Read, create, update, and delete events directly after you enable access."
                    : "Read, create, update, and delete reminders directly after you enable access."].exists)
            }
            XCTAssertTrue(app.navigationBars["Device access"].exists)
        }
        XCTAssertEqual(app.alerts.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "phone-tools-permissions-off"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testLocationSwitchTurnsOnInLight() throws {
        try locationSwitchTurnsOn(appearance: "light")
    }

    @MainActor
    func testLocationSwitchTurnsOnInDark() throws {
        try locationSwitchTurnsOn(appearance: "dark")
    }

    @MainActor
    private func locationSwitchTurnsOn(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
            "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
            "-loopdy.demo.appearance", appearance]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()

        let toggle = deviceToolSwitch("location", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[
            "Share where you are when your agent asks, for things like finding places near you."].exists)
        capture("device-access-location-off-\(appearance)", in: app)
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let on = NSPredicate(format: "value == '1'")
        expectation(for: on, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        let note = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Only while bighelp is open.'"))
        XCTAssertTrue(note.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        capture("device-access-location-on-\(appearance)", in: app)
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

    @MainActor
    private func deviceToolSwitch(_ capability: String, in app: XCUIApplication) -> XCUIElement {
        let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
        let target = app.switches["permissions.device-tools.\(capability)"].firstMatch
        for _ in 0..<6 where !target.exists || !target.isHittable { form.swipeUp() }
        return app.switches["permissions.device-tools.\(capability)"].firstMatch
    }
}
