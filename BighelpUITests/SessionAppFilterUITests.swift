import XCTest

/// Sessions on demo data: Hermes, Codex and Claude Code above the list, on one computer
/// and on all of them. Codex and Claude Code cover the chats Hermes already brought in
/// and the ones still in those apps. Set BIGHELP_APP_FILTER_EVIDENCE (TEST_RUNNER_…) to
/// save screenshots.
final class SessionAppFilterUITests: BighelpUITestCase {
    @MainActor
    func testOneComputerFiltersHermesCodexAndClaudeCode() throws {
        let app = launch(allHosts: false)
        openRootTab("tab.sessions", in: app)
        let codex = segment("Codex", in: app)
        XCTAssertTrue(codex.waitForExistence(timeout: 15), "The choice sits above the list")
        save("sessions-app-all", app)

        codex.tap()
        XCTAssertTrue(row(containing: "Started in Codex", in: app).waitForExistence(timeout: 5),
                      "Chats Hermes brought in from Codex")
        XCTAssertFalse(row(containing: "Started in Telegram", in: app).exists, "Hermes' own chats are filtered out")
        XCTAssertTrue(scrollTo(otherApp("sessions.other-app.Polish the Mac menus", in: app), in: app),
                      "And chats still in Codex, after the ones in Hermes")
        XCTAssertFalse(otherApp("sessions.other-app.Trip budget script", in: app).exists, "Not Claude Code's")
        save("sessions-app-codex", app)

        scrollToTop(app)
        segment("Claude Code", in: app).tap()
        XCTAssertTrue(row(containing: "Started in Claude Code", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "Started in Codex", in: app).exists)
        XCTAssertTrue(scrollTo(otherApp("sessions.other-app.Trip budget script", in: app), in: app))
        save("sessions-app-claude-code", app)
        scrollToTop(app)

        segment("Hermes", in: app).tap()
        XCTAssertTrue(row(containing: "Started in Telegram", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "Started in Codex", in: app).exists)
        XCTAssertFalse(otherApp("sessions.other-app.Polish the Mac menus", in: app).exists,
                       "Chats still in other apps aren't Hermes chats")
        save("sessions-app-hermes", app)

        // The filter menu asks one labeled question at a time.
        let filters = app.descendants(matching: .any).matching(identifier: "sessions.filters").firstMatch
        filters.tap()
        let agent = choice("Agent", in: app)
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "Agent is its own choice")
        XCTAssertTrue(agent.label.contains("All agents"), "It says what it's set to: \(agent.label)")
        XCTAssertTrue(choice("Type", in: app).exists)
        XCTAssertTrue(choice("Project", in: app).exists)
        save("sessions-filter-menu", app)
        agent.tap()
        XCTAssertTrue(app.buttons["Mina Shah"].firstMatch.waitForExistence(timeout: 5), "Its own list of agents")
        save("sessions-filter-menu-agent", app)
    }

    @MainActor
    func testAllComputersFilterTheSameWayAndKeepTheChoice() throws {
        let app = launch(allHosts: true)
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["menu.chats"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All sessions"].waitForExistence(timeout: 8))

        segment("Codex", in: app).tap()
        XCTAssertTrue(app.buttons["fleet.chat.Release checklist"].waitForExistence(timeout: 8),
                      "A chat another computer brought in from Codex")
        XCTAssertFalse(app.buttons["fleet.chat.Market scan"].exists, "Hermes' own chats are filtered out")
        XCTAssertTrue(scrollTo(otherApp("fleet.other-app.Speed up the test suite", in: app), in: app),
                      "A chat still in Codex on another computer")
        XCTAssertTrue(scrollTo(otherApp("fleet.other-app.Polish the Mac menus", in: app), in: app), "And on this one")
        save("all-sessions-app-codex", app)

        scrollToTop(app)
        segment("Claude Code", in: app).tap()
        XCTAssertTrue(scrollTo(otherApp("fleet.other-app.Draft the launch post", in: app), in: app))
        XCTAssertFalse(otherApp("fleet.other-app.Speed up the test suite", in: app).exists)
        save("all-sessions-app-claude-code", app)
        scrollToTop(app)

        // A computer's own Sessions keeps the choice.
        app.buttons["fleet.filter.Home Hermes"].tap()
        XCTAssertTrue(row(containing: "Started in Claude Code", in: app).waitForExistence(timeout: 10),
                      "That computer's Sessions shows Claude Code too")
        XCTAssertTrue(segment("Claude Code", in: app).isSelected)
        XCTAssertTrue(scrollTo(otherApp("sessions.other-app.Trip budget script", in: app), in: app))
        save("one-computer-in-all-hosts-claude-code", app)
    }

    @MainActor private func launch(allHosts: Bool) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-bighelp.hosts.all-hosts", allHosts ? "YES" : "NO",
                               "-loopdy.home.opens-chat", "NO"]
        app.launch()
        return app
    }

    /// A filter's own row in the filter menu, which reads "Agent, All agents".
    @MainActor private func choice(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// Lists build rows as they come on screen: swipe until the element is there.
    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1.5), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 where !segment("All", in: app).isHittable { app.swipeDown() }
    }

    @MainActor private func segment(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "sessions.app-filter").firstMatch.buttons[title]
    }

    @MainActor private func otherApp(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func row(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                             "session.row.", text)).firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_APP_FILTER_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
