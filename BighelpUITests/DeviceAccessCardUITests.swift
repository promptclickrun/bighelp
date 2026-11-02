import XCTest

/// An agent's call to a Device access tool that's off, on the demo data (`-test-device-access-card`):
/// the chat shows a card, Turn on flips the same Device access switch and the call goes on, and Not now
/// refuses it. Apple Health is in Device access with its one-time note about where the data goes.
final class DeviceAccessCardUITests: BighelpUITestCase {
    @MainActor
    func testAReminderCardTurnsOnTheSwitchAndTheCallGoesOnInLight() throws {
        try reminderCardTurnsOn(appearance: "light")
    }

    @MainActor
    func testAReminderCardTurnsOnTheSwitchAndTheCallGoesOnInDark() throws {
        try reminderCardTurnsOn(appearance: "dark")
    }

    @MainActor
    private func reminderCardTurnsOn(appearance: String) throws {
        let app = launch(appearance, call: "reminders.list")
        openDemoChat(in: app)
        let card = element("device-access.card.reminders", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The agent's call shows a card")
        XCTAssertTrue(app.staticTexts["Turn on Reminders?"].exists)
        capture("device-access-card-reminders-\(appearance)", in: app)
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        openDeviceAccess(in: app)
        XCTAssertEqual(deviceToolSwitch("reminders", in: app).value as? String, "1", "The same switch is on")
        XCTAssertTrue(app.staticTexts["Demo call reminders.list came back with 2 items."].waitForExistence(timeout: 5),
                      "The call that asked went on and came back")
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor
    func testNotNowRefusesTheCallAndLeavesTheSwitchOff() throws {
        let app = launch("light", call: "reminders.list")
        openDemoChat(in: app)
        let card = element("device-access.card.reminders", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        app.buttons["device-access.card.not-now"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        openDeviceAccess(in: app)
        XCTAssertEqual(deviceToolSwitch("reminders", in: app).value as? String, "0")
        XCTAssertTrue(app.staticTexts["Demo call reminders.list was refused: permission_declined."]
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testAppleHealthIsInDeviceAccessWithItsSharingNoteInLight() throws {
        try appleHealthRow(appearance: "light")
    }

    @MainActor
    func testAppleHealthIsInDeviceAccessWithItsSharingNoteInDark() throws {
        try appleHealthRow(appearance: "dark")
    }

    /// Where App Review looks: Settings › Device access › Apple Health, off until the person turns it on,
    /// with every kind of data it reads named, and a note about where the data goes before iOS asks.
    @MainActor
    private func appleHealthRow(appearance: String) throws {
        let app = launch(appearance, call: nil)
        openDeviceAccess(in: app)
        let toggle = deviceToolSwitch("health", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Off until the person turns it on")
        XCTAssertTrue(app.staticTexts["Apple Health"].exists)
        let detail = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Read only. Your agent can read steps'"))
        XCTAssertTrue(detail.firstMatch.exists)
        capture("device-access-health-off-\(appearance)", in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let note = element("device-access.health-sharing", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5), "The sharing note comes first")
        XCTAssertTrue(app.staticTexts["Share Health data with your agent?"].exists)
        capture("device-access-health-sharing-\(appearance)", in: app)
        app.buttons["device-access.health-sharing.continue"].firstMatch.tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 8)
        capture("device-access-health-on-\(appearance)", in: app)
    }

    @MainActor
    func testAHealthCardShowsTheSharingNoteBeforeTurningOn() throws {
        let app = launch("light", call: "health.read")
        openDemoChat(in: app)
        let card = element("device-access.card.health", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        XCTAssertTrue(element("device-access.card.health-sharing", in: app).waitForExistence(timeout: 5))
        capture("device-access-card-health-sharing-light", in: app)
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        openDeviceAccess(in: app)
        XCTAssertEqual(deviceToolSwitch("health", in: app).value as? String, "1")
        XCTAssertTrue(app.staticTexts["Demo call health.read came back with 7 items."].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launch(_ appearance: String, call: String?) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.demo.appearance", appearance,
                               "-test-device-access-card", call ?? "none"]
        app.launch()
        return app
    }

    @MainActor
    private func openDemoChat(in app: XCUIApplication) {
        let chat = app.buttons["session.row.demo-finance"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.tap()
        XCTAssertTrue(app.buttons["chat.menu"].firstMatch.waitForExistence(timeout: 10), "The chat opened")
    }

    @MainActor
    private func openDeviceAccess(in app: XCUIApplication) {
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func deviceToolSwitch(_ capability: String, in app: XCUIApplication) -> XCUIElement {
        let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
        let target = app.switches["permissions.device-tools.\(capability)"].firstMatch
        for _ in 0..<6 where !target.exists || !target.isHittable { form.swipeUp() }
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
