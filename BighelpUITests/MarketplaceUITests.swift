import XCTest

/// The Marketplace on the demo data with Advanced options off: Settings › Apps & skills and a bot's own
/// from its profile, each with Skills, Plugins, this week's featured plugin and Messaging apps, every one
/// opening its page. Apps & skills lists the apps once.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class MarketplaceUITests: BighelpUITestCase {
    @MainActor
    func testAppsAndSkillsOpensEveryWayInWithoutAdvancedOptions() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openSettings(in: app)
            settingsRow("settings.apps", in: app).tap()
            XCTAssertTrue(app.buttons["marketplace.featured"].waitForExistence(timeout: 10),
                          "Apps & skills has this week's featured plugin")
            XCTAssertTrue(app.buttons["apps.native"].exists || app.buttons["apps.composio"].exists,
                          "Apps & skills lists the apps bots can use")
            XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "apps.native").count, 1, "The apps show once")
            XCTAssertFalse(app.buttons["marketplace.mcp"].exists, "MCP servers wait for Advanced options")
            evidence("apps-and-skills-\(appearance)", app)

            open("plugins", expecting: "plugins.hero", in: app)
            open("skills", expecting: "skills.hero", in: app)
            open("messaging", expecting: nil, in: app)

            app.buttons["marketplace.featured"].tap()
            XCTAssertTrue(app.buttons["plugin.install"].waitForExistence(timeout: 5), "The featured plugin opens its page")
            app.terminate()
        }
    }

    @MainActor
    func testABotsProfileOpensItsOwnMarketplace() {
        let app = launch(appearance: "light", extra: ["-preview-ui-v3", "-loopdy.home.landing", "bots"])
        openPrimaryProfileInfo(app)

        let row = app.buttons["simple-bots.profile.marketplace"]
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "A bot's profile has its own Marketplace")
        row.tap()
        XCTAssertTrue(app.buttons["marketplace.featured"].waitForExistence(timeout: 10))
        evidence("marketplace-bot-light", app)
        open("skills", expecting: "skills.hero", in: app)
        open("messaging", expecting: nil, in: app)
        XCTAssertFalse(app.buttons["marketplace.apps"].exists, "The bot's apps are in its Connections")
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
            let app = launch(appearance: appearance, extra: ["-preview-ui-v3", "-loopdy.home.landing", "bots"])
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

    /// A bot's profile sets the project its new chats start in, for that bot.
    @MainActor
    func testABotsProfileChoosesItsActiveProject() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-preview-ui-v3", "-loopdy.home.landing", "bots"])
            openPrimaryProfileInfo(app)

            let row = app.buttons["simple-bots.profile.active-project"]
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 5), "A bot's profile has Active Project")
            XCTAssertTrue(row.label.contains("bighelp"), "The row names the current project: \(row.label)")
            row.tap()
            let current = app.buttons["bot-project.loopdy"]
            let home = app.buttons["bot-project.home"]
            XCTAssertTrue(current.waitForExistence(timeout: 10), "Active Project lists the bot's projects")
            XCTAssertTrue(current.isSelected, "The current project is checked")
            XCTAssertFalse(home.isSelected)
            evidence("bot-active-project-\(appearance)", app)
            home.tap()
            XCTAssertTrue(waitUntil { home.isSelected && !current.isSelected }, "Choosing a project makes it current")
            app.buttons["bot-project.done"].tap()
            XCTAssertTrue(waitUntil { row.label.contains("Home") }, "The row names the new project: \(row.label)")
            app.terminate()
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
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
            goBack(in: app)
        } else {
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "\(section) opens its page", file: file, line: line)
            evidence("marketplace-\(section)", app)
            goBack(in: app)
        }
        let back = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
                                                                         ["marketplace.screen", "apps.hub"])).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back returns to the page", file: file, line: line)
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                                "-loopdy.settings.nerd-mode", "NO"] + extra
        app.launch()
        return app
    }

    /// The sheet's own Back: the screen behind a sheet has a navigation bar too.
    @MainActor
    private func goBack(in app: XCUIApplication) {
        let back = app.buttons["BackButton"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap(); return }
        let bar = app.navigationBars.buttons.element(boundBy: 0)
        if bar.waitForExistence(timeout: 1) { bar.tap() }
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
