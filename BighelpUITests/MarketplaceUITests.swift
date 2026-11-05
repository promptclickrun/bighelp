import XCTest

/// The Marketplace on the demo data with Nerd Mode off: Settings › Marketplace and a bot's own from its
/// profile, each with this week's featured plugin and the four ways in, every one opening its page.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class MarketplaceUITests: BighelpUITestCase {
    @MainActor
    func testSettingsMarketplaceOpensEveryWayInWithoutNerdMode() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openSettings(in: app)
            let row = settingsRow("settings.marketplace", in: app)
            XCTAssertTrue(row.exists, "Settings lists the Marketplace without Nerd Mode")
            row.tap()
            XCTAssertTrue(app.buttons["marketplace.featured"].waitForExistence(timeout: 10),
                          "The Marketplace opens on this week's featured plugin")
            XCTAssertTrue(app.buttons["marketplace.popular.local-models"].exists, "The most starred plugins show")
            evidence("marketplace-settings-\(appearance)", app)

            open("plugins", expecting: "plugins.hero", in: app)
            open("skills", expecting: "skills.hero", in: app)
            open("apps", expecting: "marketplace.apps.page", in: app)
            XCTAssertTrue(app.buttons["apps.native"].exists || app.buttons["apps.composio"].exists,
                          "Apps lists the apps agents can use")
            goBack(in: app)
            open("messaging", expecting: nil, in: app)

            app.buttons["marketplace.featured"].tap()
            XCTAssertTrue(app.buttons["plugin.install"].waitForExistence(timeout: 5), "The featured plugin opens its page")
            app.terminate()
        }
    }

    @MainActor
    func testABotsProfileOpensItsOwnMarketplace() {
        let app = launch(appearance: "light", extra: ["-preview-ui-v3", "-bighelp.settings.simple-bots", "YES"])
        openPrimaryProfileInfo(app)

        let row = app.buttons["simple-bots.profile.marketplace"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "A bot's profile has its own Marketplace")
        row.tap()
        XCTAssertTrue(app.buttons["marketplace.featured"].waitForExistence(timeout: 10))
        evidence("marketplace-bot-light", app)
        open("skills", expecting: "skills.hero", in: app)
        open("mcp", expecting: nil, in: app)
        app.buttons["marketplace.done"].tap()
        XCTAssertTrue(app.buttons["marketplace.done"].waitForNonExistence(timeout: 5))

        // The Skills Hub, MCP servers and Plugins are in the Marketplace, not in Advanced Options.
        let advanced = app.buttons["simple-bots.profile.advanced-options"]
        for _ in 0..<4 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        XCTAssertTrue(app.descendants(matching: .any)["advanced.options"].waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(app.buttons["advanced.page.logs"].exists, "Advanced Options keeps its expert pages")
        for page in ["skillsHub", "toolServers", "plugins"] {
            XCTAssertFalse(app.buttons["advanced.page.\(page)"].exists, "\(page) is in the Marketplace")
        }
        app.buttons["advanced.done"].tap()
    }

    /// A bot's profile has its Core Files (SOUL.md and the rest, which open in the editor) and its Connections.
    @MainActor
    func testABotsProfileOpensItsCoreFilesAndConnections() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-preview-ui-v3", "-bighelp.settings.simple-bots", "YES"])
            openPrimaryProfileInfo(app)

            let coreFiles = app.buttons["simple-bots.profile.core-files"]
            for _ in 0..<4 where !coreFiles.isHittable { app.swipeUp() }
            XCTAssertTrue(coreFiles.waitForExistence(timeout: 5), "A bot's profile has Core Files")
            coreFiles.tap()
            for kind in ["soul", "user", "memory", "agents"] {
                XCTAssertTrue(app.buttons["core-files.\(kind)"].waitForExistence(timeout: 10), "Core Files lists \(kind)")
            }
            evidence("core-files-\(appearance)", app)
            app.buttons["core-files.soul"].tap()
            XCTAssertTrue(app.buttons["markdown-file.done"].waitForExistence(timeout: 10), "SOUL.md opens in the editor")
            evidence("core-files-soul-\(appearance)", app)
            app.buttons["markdown-file.done"].tap()
            app.buttons["core-files.done"].tap()
            XCTAssertTrue(app.buttons["core-files.done"].waitForNonExistence(timeout: 5))

            let connections = app.buttons["simple-bots.profile.connections"]
            for _ in 0..<4 where !connections.isHittable { app.swipeUp() }
            XCTAssertTrue(connections.waitForExistence(timeout: 5), "A bot's profile has Connections")
            connections.tap()
            XCTAssertTrue(app.buttons["bot.connections.device-access"].waitForExistence(timeout: 10),
                          "Connections leads with this device's access")
            evidence("bot-connections-\(appearance)", app)
            app.buttons["bot.connections.done"].tap()
            app.terminate()
        }
    }

    @MainActor
    private func openPrimaryProfileInfo(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.primary"].tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        // A tap while the chat is still sliding in can miss; one more is enough.
        identity.tap()
        if !profile.waitForExistence(timeout: 5) { identity.tap() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        app.buttons["simple-bots.profile.tab.info"].tap()
    }

    /// Opens one way in, checks its page and goes back. `expecting` nil checks only that a page opened.
    @MainActor
    private func open(_ section: String, expecting identifier: String?, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["marketplace.\(section)"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The Marketplace lists \(section)", file: file, line: line)
        row.tap()
        if let identifier {
            let opened = app.descendants(matching: .any)[identifier].firstMatch.waitForExistence(timeout: 10)
            if !opened { evidence("marketplace-\(section)-missing", app); print(app.debugDescription) }
            XCTAssertTrue(opened, "\(section) opens its page", file: file, line: line)
            if identifier != "marketplace.apps.page" { goBack(in: app) }
        } else {
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "\(section) opens its page", file: file, line: line)
            evidence("marketplace-\(section)", app)
            goBack(in: app)
        }
        if identifier != "marketplace.apps.page" {
            XCTAssertTrue(app.descendants(matching: .any)["marketplace.screen"].firstMatch.waitForExistence(timeout: 5),
                          "Back returns to the Marketplace", file: file, line: line)
        }
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                                "-loopdy.settings.nerd-mode", "NO"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
