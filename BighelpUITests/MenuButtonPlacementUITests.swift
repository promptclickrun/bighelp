import XCTest

/// ☰ sits in the same spot on every screen with a bottom bar (Agents' spot: the top bar's
/// leading button), and it's always there. Chat, Agents, Feed and Files with Agents pinned
/// to the bottom bar, on demo data. Set BIGHELP_MENU_PLACEMENT_EVIDENCE (TEST_RUNNER_…) to
/// save screenshots.
final class MenuButtonPlacementUITests: BighelpUITestCase {
    @MainActor
    func testMenuButtonSitsInOnePlaceOnEveryScreen() throws {
        let app = launch()
        var frames: [String: CGRect] = [:]
        for (tab, name) in [("tab.agents", "agents"), ("tab.sessions", "chat"), ("tab.feed", "feed"),
                            ("tab.apps", "files"), ("tab.agents", "agents-again")] {
            app.buttons[tab].firstMatch.tap()
            // Let the switch settle before measuring.
            Thread.sleep(forTimeInterval: 1.2)
            let menu = menuButton(in: app)
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "☰ on \(name)")
            frames[name] = menu.frame
            save("menu-\(name)", app)
        }
        // The top bar reports ☰'s glyph and our header its whole tap area, so compare centers.
        let expected = try XCTUnwrap(frames["agents"])
        for (name, frame) in frames.sorted(by: { $0.key < $1.key }) {
            print("☰ \(name): \(frame)")
            XCTAssertEqual(frame.midX, expected.midX, accuracy: 1, "☰ moves sideways on \(name): \(frame) vs \(expected)")
            XCTAssertEqual(frame.midY, expected.midY, accuracy: 1, "☰ moves up or down on \(name): \(frame) vs \(expected)")
        }
    }

    @MainActor
    func testAgentsAlwaysHasTheMenuButtonAfterChat() throws {
        let app = launch()
        for round in 1...12 {
            app.buttons["tab.sessions"].firstMatch.tap()
            XCTAssertTrue(menuButton(in: app).waitForExistence(timeout: 10), "☰ in the chat, round \(round)")
            app.buttons["tab.agents"].firstMatch.tap()
            let menu = app.buttons["home.drawer.open"].firstMatch
            let shown = menu.waitForExistence(timeout: 5) && menu.isHittable
            if !shown { save("agents-missing-menu-\(round)", app) }
            XCTAssertTrue(shown, "☰ on Agents after Chat, round \(round)")
        }
    }

    /// Agents in the bottom bar still has its ☰ row, like Settings: quick screens hide the bar.
    @MainActor
    func testPinnedAgentsAndSettingsStayInTheMenu() throws {
        let app = launch()
        app.buttons["tab.feed"].firstMatch.tap()
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let agents = app.buttons["menu.agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "Agents stays in ☰ while pinned")
        XCTAssertFalse(app.buttons["menu.feed"].exists, "Other pinned places aren't listed twice")
        save("menu-pinned-agents", app)
        agents.tap()
        XCTAssertTrue(app.buttons["tab.agents"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.agents"].isSelected, "☰'s Agents opens the Agents tab")

        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let settings = app.buttons["menu.settings"]
        for _ in 0..<4 where !settings.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(settings.isHittable, "Settings stays in ☰")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-bighelp.app-layout", "{pinned=(agents,feed,files);menu=();}"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.agents"].waitForExistence(timeout: 20), "Agents is pinned")
        return app
    }

    /// The chat's ☰ has its own name; every other screen's is home.drawer.open.
    @MainActor private func menuButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.menu", "home.drawer.open"]))
            .allElementsBoundByIndex.first { $0.isHittable } ?? app.buttons["home.drawer.open"].firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MENU_PLACEMENT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
