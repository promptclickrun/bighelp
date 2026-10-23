import XCTest

/// Settings › Appearance › App layout on demo data: Feed, Ideas and Goals leave the bottom
/// bar for Kanban, Workflows and Scheduled tasks, and stay one tap away in ☰.
/// Set BIGHELP_APP_LAYOUT_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class AppLayoutUITests: BighelpUITestCase {
    @MainActor
    func testSwappingBoardsForPagesKeepsBoardsInTheMenu() throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.feed"].waitForExistence(timeout: 20), "Feed starts in the bottom bar")

        openAppLayout(in: app)
        save("app-layout-standard", app)
        for place in ["feed", "ideas", "goals"] {
            let remove = app.buttons["app-layout.remove.\(place)"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5), place)
            remove.tap()
        }
        for place in ["kanban", "workflows", "scheduledTasks"] {
            let add = app.buttons["app-layout.add.\(place)"]
            XCTAssertTrue(scrollTo(add, in: app), place)
            add.tap()
        }
        XCTAssertTrue(scrollTo(app.descendants(matching: .any)["app-layout.menu.feed"], in: app),
                      "Feed moved to the menu")
        save("app-layout-custom", app)
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)["app-layout.bar.kanban"].waitForExistence(timeout: 5))

        // Back to the app: the bar holds the pages now.
        closeSettings(in: app)
        let kanban = app.buttons["tab.kanban"]
        XCTAssertTrue(kanban.waitForExistence(timeout: 10), "Kanban is in the bottom bar")
        XCTAssertTrue(app.buttons["tab.workflows"].exists && app.buttons["tab.scheduled-tasks"].exists)
        XCTAssertFalse(app.buttons["tab.feed"].exists, "Feed left the bar")
        kanban.tap()
        XCTAssertTrue(app.buttons["tab.kanban"].waitForExistence(timeout: 5), "The bar stays on its tab")
        XCTAssertTrue(app.buttons["tab.kanban"].isSelected)
        save("app-layout-kanban-tab", app)

        // Feed is still one tap away in ☰.
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let feed = app.buttons["menu.feed"]
        XCTAssertTrue(scrollTo(feed, in: app), "Feed is in the menu")
        XCTAssertFalse(app.buttons["menu.kanban"].exists, "Kanban isn't listed twice")
        save("app-layout-menu", app)
        feed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.feed"].waitForExistence(timeout: 10), "Feed opens")
        save("app-layout-feed", app)
    }

    /// ☰ › Sessions opens every chat, easier to find than Recent sessions' See all. Pinned, it's
    /// a tab of its own while Chat stays the agent's chat.
    @MainActor
    func testSessionsOpensEveryChatFromTheMenuAndItsOwnTab() throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 30), "Chat opens the agent's chat")

        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let sessions = app.buttons["menu.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 5), "Sessions has its own row in the menu")
        save("sessions-menu", app)
        sessions.tap()
        let list = app.descendants(matching: .any)["sessions.screen"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The menu's Sessions opens every chat")
        save("sessions-list-from-menu", app)

        openAppLayout(in: app)
        let add = app.buttons["app-layout.add.sessions"]
        app.buttons["app-layout.remove.files"].tap()
        XCTAssertTrue(scrollTo(add, in: app), "Sessions can go in the bottom bar")
        add.tap()
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)["app-layout.bar.sessions"].waitForExistence(timeout: 5))
        save("sessions-app-layout", app)
        closeSettings(in: app)

        let tab = app.buttons["tab.session-list"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Sessions is in the bottom bar")
        XCTAssertTrue(list.exists && tab.isSelected, "The list is Sessions' tab")
        XCTAssertFalse(app.buttons["tab.sessions"].isSelected)
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 10), "Chat still opens the agent's chat")
        app.buttons["tab.session-list"].firstMatch.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The Sessions tab opens every chat")
        XCTAssertTrue(app.buttons["tab.session-list"].firstMatch.isSelected)
        save("sessions-tab", app)
    }

    @MainActor
    func testResetAsksFirstThenRestoresTheDefaultLayout() throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openAppLayout(in: app)
        let reset = app.buttons["app-layout.reset"]
        XCTAssertTrue(scrollTo(reset, in: app))
        XCTAssertFalse(reset.isEnabled, "Nothing to reset yet")

        app.swipeDown(); app.swipeDown()
        app.buttons["app-layout.remove.goals"].tap()
        XCTAssertTrue(scrollTo(reset, in: app))
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        let confirm = app.alerts.buttons["Reset"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "It asks first")
        save("app-layout-reset-confirm", app)
        app.alerts.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(reset.isEnabled, "Cancel keeps the change")

        reset.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)["app-layout.bar.goals"].waitForExistence(timeout: 5),
                      "Goals is back in the bottom bar")
        XCTAssertTrue(scrollTo(reset, in: app))
        XCTAssertFalse(reset.isEnabled, "Back to the default")
    }

    @MainActor private func openAppLayout(in app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(scrollTo(settings, in: app))
        settings.tap()
        let appearance = settingsRow("settings.themes", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let layout = app.buttons["settings.appearance.app-layout"]
        XCTAssertTrue(scrollTo(layout, in: app), "App layout is under Appearance")
        layout.tap()
        XCTAssertTrue(app.descendants(matching: .any)["app-layout"].waitForExistence(timeout: 5))
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_APP_LAYOUT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
