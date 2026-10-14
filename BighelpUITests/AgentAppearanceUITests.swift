import XCTest

/// An agent's `iphone_appearance` call on the demo data (`-test-agent-appearance`): opening a chat
/// lets it change the look, Appearance shows the result, and the Device access switch stops it.
final class AgentAppearanceUITests: BighelpUITestCase {
    @MainActor
    func testAgentMakesTheAppDarkWithRoseBubbles() throws {
        let app = launch(startingIn: "light", call: #"{"mode":"dark","color":"rose"}"#)
        openDemoChat(in: app)
        expectAppearance(mode: "Dark", color: "rose", in: app)
        capture("agent-appearance-studio-dark-rose", in: app)
        closeSettings(in: app)
        capture("agent-appearance-chat-dark-rose", in: app)
    }

    @MainActor
    func testAgentMakesTheAppLightWithOceanBubbles() throws {
        let app = launch(startingIn: "dark", call: #"{"mode":"light","color":"ocean"}"#)
        openDemoChat(in: app)
        expectAppearance(mode: "Light", color: "ocean", in: app)
        capture("agent-appearance-studio-light-ocean", in: app)
        closeSettings(in: app)
        capture("agent-appearance-chat-light-ocean", in: app)
    }

    @MainActor
    func testTurnedOffTheAgentCannotChangeTheLook() throws {
        let app = launch(startingIn: "light", call: #"{"mode":"dark","color":"rose"}"#,
                         extra: ["-bighelp.device-tools.appearance", "NO"])
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let toggle = appearanceSwitch(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        closeSettings(in: app)
        openDemoChat(in: app)
        // The call is sent as the chat opens; give it time to (not) land.
        Thread.sleep(forTimeInterval: 2)
        expectAppearance(mode: "Light", color: "lavender", in: app)
    }

    @MainActor
    func testDeviceAccessShowsTheSwitchOnInLight() throws {
        try deviceAccessShowsTheSwitch(appearance: "light")
    }

    @MainActor
    func testDeviceAccessShowsTheSwitchOnInDark() throws {
        try deviceAccessShowsTheSwitch(appearance: "dark")
    }

    @MainActor
    private func deviceAccessShowsTheSwitch(appearance: String) throws {
        let app = launch(startingIn: appearance, call: nil)
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let toggle = appearanceSwitch(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1", "On until the person turns it off")
        XCTAssertTrue(app.staticTexts["Let agents change how bighelp looks"].exists)
        capture("device-access-appearance-on-\(appearance)", in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.alerts.count, 0, "No iOS permission is asked for")
    }

    @MainActor
    private func launch(startingIn appearance: String, call: String?, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.demo.appearance", appearance] + extra
        if let call { app.launchArguments += ["-test-agent-appearance", call] }
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

    /// Settings › Appearance shows the agent's change like one made there.
    @MainActor
    private func expectAppearance(mode: String, color: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        openSettings(in: app, file: file, line: line)
        settingsRow("settings.themes", in: app, file: file, line: line).tap()
        let picker = app.segmentedControls["appearance.mode"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), file: file, line: line)
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: picker.buttons[mode].firstMatch)
        let swatch = app.descendants(matching: .any)["appearance.bubble.\(color)"].firstMatch
        let studio = app.descendants(matching: .any)["appearance.studio"].firstMatch
        for _ in 0..<4 where !swatch.isHittable { studio.swipeUp() }
        expectation(for: selected, evaluatedWith: swatch)
        waitForExpectations(timeout: 8)
    }

    @MainActor
    private func appearanceSwitch(in app: XCUIApplication) -> XCUIElement {
        let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
        let target = app.switches["permissions.device-tools.appearance"].firstMatch
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
