import XCTest

/// Settings is one short list of rows, each opening one page; Nerd Mode adds the
/// host's tools with System (update Hermes, restart the gateway) first. Set
/// BIGHELP_SETTINGS_EVIDENCE (TEST_RUNNER_BIGHELP_SETTINGS_EVIDENCE) to save screenshots.
final class SettingsCleanupUITests: BighelpUITestCase {
    @MainActor
    func testSettingsIsOneShortListAndNerdModeAddsHermes() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openSettings(in: app)
            save("settings-top-\(appearance)", app)
            for row in ["settings.themes", "settings.menu.chat", "settings.chat.voice-settings",
                        "settings.menu.notifications",
                        "settings.menu.connectivityAndNotifications", "settings.menu.permissions",
                        "settings.menu.help", "settings.hermes.system", "settings.hermes-tools"] {
                XCTAssertTrue(settingsRow(row, in: app).exists, row)
            }
            save("settings-bottom-\(appearance)", app)
            // The old Chat details, Advanced and Display & data sections are gone from the first page.
            XCTAssertFalse(app.buttons["settings.advanced"].exists)
            XCTAssertFalse(app.buttons["settings.advanced.workspace"].exists)
            XCTAssertFalse(app.switches["settings.chat.fold-completed-turns"].exists)

            // Chat's page holds the everyday toggles, and with Nerd Mode what chats show.
            settingsRow("settings.menu.chat", in: app).tap()
            XCTAssertTrue(app.switches["settings.chat.response-haptics"].waitForExistence(timeout: 5))
            let fold = app.switches["settings.chat.fold-completed-turns"]
            for _ in 0..<4 where !fold.exists { app.swipeUp() }
            XCTAssertTrue(fold.exists, "Nerd Mode's chat settings live on the Chat page")
            save("settings-chat-\(appearance)", app)
            app.navigationBars.buttons.element(boundBy: 0).tap()

            // Hermes tools open from Settings; ☰ no longer has its own entry.
            settingsRow("settings.hermes-tools", in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.hub"].firstMatch.waitForExistence(timeout: 5))
            save("settings-hermes-tools-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testWithoutNerdModeSettingsHasNoHostTools() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        openSettings(in: app)
        let nerdMode = app.switches["settings.nerd-mode"].firstMatch
        for _ in 0..<8 where !(nerdMode.exists && nerdMode.isHittable) { app.swipeUp() }
        XCTAssertTrue(nerdMode.exists)
        XCTAssertFalse(app.buttons["settings.hermes.system"].exists)
        XCTAssertFalse(app.buttons["settings.hermes-tools"].exists)
        save("settings-no-nerd-mode", app)
    }

    @MainActor
    func testSystemPutsUpdateAndRestartFirst() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-system-page",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        let update = app.buttons["system.hermes.update"]
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        XCTAssertTrue(update.label.contains("Update Hermes"), update.label)
        XCTAssertTrue(update.label.contains("12 commits behind"), update.label)
        let restart = app.buttons["system.gateway.restart"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5))
        XCTAssertTrue(restart.label.contains("Restart Hermes Gateway"), restart.label)
        XCTAssertTrue(update.frame.maxY < restart.frame.minY, "Update comes first")
        XCTAssertTrue(restart.isHittable, "Both main actions show without scrolling")
        save("system-behind", app)

        update.tap()
        let confirm = app.buttons["Update Hermes"].firstMatch
        XCTAssertTrue(app.staticTexts["Update Hermes?"].waitForExistence(timeout: 5))
        XCTAssertTrue(confirm.exists)
        save("system-update-confirm", app)
        dismissConfirmation("Update Hermes?", in: app)

        restart.tap()
        XCTAssertTrue(app.staticTexts["Restart the Hermes gateway?"].waitForExistence(timeout: 5))
        save("system-restart-confirm", app)
        dismissConfirmation("Restart the Hermes gateway?", in: app)
    }

    @MainActor
    func testSystemSaysWhenHermesIsUpToDate() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-system-page",
                               "-test-system-page-current", "-loopdy.demo.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hermes is up to date"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["system.hermes.update"].exists)
        XCTAssertTrue(app.buttons["system.hermes.check"].exists)
        save("system-current-dark", app)
    }

    /// iOS 26 shows these as a popover without Cancel; a tap outside closes it.
    @MainActor
    private func dismissConfirmation(_ title: String, in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap() }
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(timeout: 5), "\(title) closes without acting")
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
