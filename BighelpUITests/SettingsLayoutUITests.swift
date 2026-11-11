import XCTest

/// Settings' first screen in short groups: You as one row, your agents and what they can use
/// (Connections, with this device's access first), the app (Modes, Appearance, ...), then System
/// and Help. Set BIGHELP_SETTINGS_EVIDENCE (TEST_RUNNER_BIGHELP_SETTINGS_EVIDENCE) to save screenshots.
final class SettingsLayoutUITests: BighelpUITestCase {
    @MainActor
    func testConnectionsHoldDeviceAccessAndModesHoldTheModeSwitches() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openSettings(in: app)
            XCTAssertTrue(app.buttons["settings.you"].waitForExistence(timeout: 5), "You is one row")
            XCTAssertFalse(app.textFields["profile.display-name"].exists, "The name box is on the You page")
            save("01-settings-\(appearance)", app)

            settingsRow("settings.menu.modes", in: app).tap()
            XCTAssertTrue(app.buttons["settings.mode.bots"].waitForExistence(timeout: 5), "Bots mode is under Modes")
            XCTAssertTrue(app.buttons["settings.mode.chat"].exists, "Chat mode is under Modes")
            XCTAssertTrue(app.buttons["settings.mode.code"].exists, "Code mode is under Modes")
            XCTAssertTrue(app.switches["settings.unified-mode-toggle"].exists, "Header mode switcher is under Modes")
            XCTAssertTrue(app.switches["settings.all-computers"].exists, "All computers switch is under Modes")
            save("02-modes-\(appearance)", app)
            app.navigationBars.buttons.firstMatch.tap()

            settingsRow("settings.apps", in: app).tap()
            let device = app.buttons["settings.connections.device-access"].firstMatch
            let composio = app.buttons["apps.composio"].firstMatch
            XCTAssertTrue(device.waitForExistence(timeout: 5), "Connections starts with this device")
            XCTAssertTrue(composio.waitForExistence(timeout: 5))
            XCTAssertLessThan(device.frame.maxY, composio.frame.minY, "This device comes before the apps")
            XCTAssertTrue(app.buttons["settings.connections.vault"].exists, "The vault sits with the apps")
            save("03-connections-\(appearance)", app)

            device.tap()
            XCTAssertTrue(app.switches["permissions.device-tools.calendar"].waitForExistence(timeout: 5),
                          "Device access opens from Connections")
            save("04-device-access-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SETTINGS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
