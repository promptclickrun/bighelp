import XCTest

/// A computer's page on a synthetic computer (`-test-system-page`): Updates and Restart up top, and with
/// Advanced options its Messaging, Upkeep and Setup groups last. The fixture has no This device rows.
/// BIGHELP_SYSTEM_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class SystemPageUITests: BighelpUITestCase {
    @MainActor
    func testUpdatesAndRestartUpTopTheRestInAdvancedGroups() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-test-system-page", "-loopdy.demo.appearance", appearance,
                                   "-loopdy.settings.nerd-mode", "YES"]
            app.launch()
            XCTAssertTrue(app.buttons["system.hermes.update"].waitForExistence(timeout: 15), "Update Hermes up top")
            XCTAssertTrue(app.buttons["system.gateway.restart"].exists, "Restart messaging under it")
            save("system-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }
            // The dialog hangs on one row, not the section, and names messaging, not the gateway.
            app.buttons["system.gateway.restart"].tap()
            XCTAssertTrue(app.staticTexts["Restart messaging?"].waitForExistence(timeout: 5), "Restart asks first")
            // iOS shows the dialog with or without Cancel; a tap outside closes it too.
            let cancel = app.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
            XCTAssertTrue(app.staticTexts["Restart messaging?"].waitForNonExistence(timeout: 5))
            let raw = app.buttons["system.raw-configuration"]
            let list = app.collectionViews.firstMatch
            let mode = app.staticTexts["Messaging mode"]
            for _ in 0..<4 where !(mode.exists && mode.isHittable) { list.swipeUp() }
            XCTAssertTrue(mode.exists, "Advanced · Messaging says messaging, not gateway")
            for _ in 0..<6 where !(raw.exists && raw.isHittable) { list.swipeUp() }
            XCTAssertTrue(raw.waitForExistence(timeout: 5), "Advanced · Setup has Edit config.yaml")
            XCTAssertTrue(app.buttons["system.diagnostics"].exists, "Advanced · Upkeep has Diagnostics")
            save("system-advanced", app)
            app.terminate()
        }
    }

    @MainActor
    func testAdvancedGroupsWaitForAdvancedOptions() throws {
        let app = makeApp()
        app.launchArguments = ["-test-system-page", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["system.hermes.update"].waitForExistence(timeout: 15))
        let list = app.collectionViews.firstMatch
        for _ in 0..<4 { list.swipeUp() }
        XCTAssertFalse(app.buttons["system.raw-configuration"].exists, "Advanced groups need Advanced options")
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SYSTEM_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
