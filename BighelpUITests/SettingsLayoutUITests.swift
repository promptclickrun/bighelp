import XCTest

/// Settings' first screen in short groups: you, your bots and what they can use (Apps & skills,
/// with this device's access first), this app (Appearance, Chat, ...), your computers, then Help. Set BIGHELP_SETTINGS_EVIDENCE (TEST_RUNNER_BIGHELP_SETTINGS_EVIDENCE) to save screenshots.
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
            XCTAssertTrue(app.switches["settings.code-mode"].exists, "Code mode keeps its own switch")
            save("02-modes-\(appearance)", app)
            app.navigationBars.buttons.firstMatch.tap()

            settingsRow("settings.apps", in: app).tap()
            let device = app.buttons["settings.connections.device-access"].firstMatch
            let composio = app.buttons["apps.composio"].firstMatch
            XCTAssertTrue(device.waitForExistence(timeout: 5), "Apps & skills starts with this device")
            XCTAssertTrue(composio.waitForExistence(timeout: 5))
            XCTAssertLessThan(device.frame.maxY, composio.frame.minY, "This device comes before the apps")
            save("03-connections-\(appearance)", app)
            // Logins comes after Apps, Skills and plugins and Talk anywhere: lower on the page.
            reach(app.buttons["settings.connections.vault"].firstMatch, in: app)
            for _ in 0..<8 where !(device.exists && device.isHittable) { app.swipeDown(velocity: .slow) }

            device.tap()
            XCTAssertTrue(app.switches["permissions.device-tools.calendar"].waitForExistence(timeout: 5),
                          "Device access opens from Apps & skills")
            save("04-device-access-\(appearance)", app)
            app.terminate()
        }
    }

    /// Settings › Chat, Notifications and Device access read in named groups (#974): each control sits
    /// under a header, a row's second line is its value or a short hint, and Nerd Mode's Advanced
    /// groups come last (the test base turns Nerd Mode on). The second pass is dark at a large text size.
    @MainActor
    func testChatNotificationsAndDeviceAccessReadInNamedGroups() throws {
        for (appearance, textSize) in [("light", String?.none), ("dark", "UICTContentSizeCategoryAccessibilityM")] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            if let textSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize] }
            app.launch()
            openSettings(in: app)

            settingsRow("settings.menu.chat", in: app).tap()
            let opensOn = app.buttons["settings.landing.screen"].firstMatch
            XCTAssertTrue(opensOn.waitForExistence(timeout: 5), "Opening leads Settings › Chat")
            XCTAssertTrue(header("Opening", in: app).exists)
            XCTAssertLessThan(header("Opening", in: app).frame.minY, opensOn.frame.minY, "Opens on sits under Opening")
            XCTAssertTrue(opensOn.label.contains("Opens on"), opensOn.label)
            save("05-chat-\(appearance)", app)
            reach(header("A bot's work", in: app), in: app)
            let work = reach(app.buttons["settings.chat.work-style"].firstMatch, in: app)
            XCTAssertTrue(work.label.contains("Shows as"), work.label)
            reach(header("In a chat", in: app), in: app)
            let title = reach(app.switches["settings.chat.session-title"].firstMatch, in: app)
            XCTAssertEqual(title.label, "Chat title", "A switch says what it is, with no sentence under it")
            reach(header("Advanced · A bot's work", in: app), in: app)
            reach(app.switches["settings.chat.fold-completed-turns"].firstMatch, in: app)
            save("06-chat-advanced-\(appearance)", app)
            reach(header("Advanced · Chat list", in: app), in: app)
            reach(app.switches["settings.show-cron-sessions"].firstMatch, in: app)
            reach(app.buttons["settings.chat.clean-up-chats"].firstMatch, in: app)
            app.navigationBars.buttons.firstMatch.tap()

            settingsRow("settings.menu.notifications", in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.notifications"].firstMatch.waitForExistence(timeout: 8))
            reach(header("This device", in: app), in: app)
            reach(header("Notify me about", in: app), in: app)
            reach(app.switches["settings.notifications.peer-chats"].firstMatch, in: app)
            save("07-notifications-\(appearance)", app)
            let quietHeader = reach(header("Quiet hours", in: app), in: app)
            let quiet = app.switches["settings.notifications.quiet-hours"].firstMatch
            // The header and the switch share a name; the switch is the one under the header.
            XCTAssertTrue(quiet.waitForExistence(timeout: 3), "The switch sits right under its header")
            XCTAssertLessThan(quietHeader.frame.minY, quiet.frame.minY)
            XCTAssertEqual(quiet.label, "Quiet hours")
            reach(app.descendants(matching: .any)["settings.notifications.details"].firstMatch, in: app)
            reach(app.buttons["settings.notifications.turn-off"].firstMatch, in: app)
            save("08-notifications-end-\(appearance)", app)
            app.navigationBars.buttons.firstMatch.tap()

            settingsRow("settings.apps", in: app).tap()
            app.buttons["settings.connections.device-access"].firstMatch.tap()
            let calendar = app.switches["permissions.device-tools.calendar"].firstMatch
            XCTAssertTrue(calendar.waitForExistence(timeout: 5))
            XCTAssertTrue(header("Your data", in: app).exists)
            XCTAssertLessThan(header("Your data", in: app).frame.minY, calendar.frame.minY, "Calendar sits under Your data")
            XCTAssertEqual(calendar.label, "Calendar", "The long description left the row")
            save("09-device-access-\(appearance)", app)
            app.buttons["permissions.device-tools.calendar.about"].firstMatch.tap()
            let done = app.buttons["permissions.about.done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "The info button shows the description in a sheet")
            save("10-device-access-about-\(appearance)", app)
            done.tap()
            reach(header("bighelp itself", in: app), in: app)
            reach(app.switches["permissions.device-tools.navigation"].firstMatch, in: app)
            app.terminate()
        }
    }

    /// One Settings in every mode (#976): you, Your bots, This app, Your computers, then Help & feedback
    /// and Advanced options. Bots mode's circle opens the same page.
    @MainActor
    func testOneSettingsInChatAndBotsMode() throws {
        for (mode, extra) in [("chat", [String]()), ("bots", ["-bighelp.settings.simple-bots", "YES"])] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"] + extra
            app.launch()
            if mode == "bots" {
                let circle = app.buttons["simple-bots.settings"]
                XCTAssertTrue(circle.waitForExistence(timeout: 15))
                circle.tap()
            } else {
                openSettings(in: app)
            }
            XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 5),
                          "\(mode): the one Settings")
            XCTAssertTrue(header("Your bots", in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["settings.default-model"].exists, "Models")
            save("11-root-\(mode)", app)
            reach(header("This app", in: app), in: app)
            reach(header("Your computers", in: app), in: app)
            let advanced = reach(app.switches["settings.nerd-mode"].firstMatch, in: app)
            XCTAssertEqual(advanced.label, "Advanced options")
            save("12-root-end-\(mode)", app)
            app.terminate()
        }
    }

    /// A Form section's header; Forms draw headers in capitals, so the match ignores case.
    @MainActor
    private func header(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", text)).firstMatch
    }

    /// Scrolls the page down until the header or control is on screen. Forms build their rows as they
    /// come into view and drop them as they leave, so the test reads each group in page order.
    @MainActor
    @discardableResult
    private func reach(_ element: XCUIElement, in app: XCUIApplication,
                       file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        // Slow, so a swipe never carries a short group past the screen.
        for _ in 0..<16 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.exists, "\(element) is on the page", file: file, line: line)
        return element
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
