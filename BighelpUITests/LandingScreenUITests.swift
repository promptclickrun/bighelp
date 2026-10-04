import XCTest

/// Settings › Chat › Open on: each choice is where a cold launch lands, and
/// Start with picks the agent. Demo data. Set BIGHELP_LANDING_EVIDENCE
/// (TEST_RUNNER_BIGHELP_LANDING_EVIDENCE) to a folder to save the picker in
/// light and dark.
final class LandingScreenUITests: BighelpUITestCase {
    private func launch(_ app: XCUIApplication, landing: String?, extra: [String] = []) {
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO"]
            + (landing.map { ["-loopdy.home.landing", $0] } ?? []) + extra
        app.launch()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    func testEachChoiceOpensOnItsScreen() throws {
        let app = makeApp()
        let screens: [(landing: String, identifier: String, tab: String?)] = [
            ("feed", "board.feed", "tab.feed"),
            ("ideas", "board.ideas", "tab.ideas"),
            ("goals", "board.goals", "tab.goals"),
            ("projects", "projects.screen", nil),
            ("kanban", "kanban.screen", nil),
            ("agents", "agents.screen", nil),
            ("last-chat", "agent.hero.avatar", nil),
            ("sessions", "sessions.screen", nil),
            ("all-agents", "fleet.home", nil),
        ]
        for screen in screens {
            launch(app, landing: screen.landing)
            XCTAssertTrue(element(screen.identifier, in: app).waitForExistence(timeout: 25),
                          "\(screen.landing) opens on \(screen.identifier)")
            if let tab = screen.tab {
                XCTAssertTrue(app.buttons[tab].firstMatch.isSelected, "\(screen.landing): its tab is selected")
            }
            if screen.landing == "last-chat" {
                XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5), "A chat is open")
            }
            if screen.landing == "sessions" {
                XCTAssertTrue(app.navigationBars["Sessions"].exists, "All sessions, to pick a recent one")
            }
            if screen.landing == "agents" {
                XCTAssertFalse(element("fleet.home", in: app).exists, "One computer's agents, not every computer's")
            }
            app.terminate()
        }
    }

    /// The real controls: pick a screen and an agent in Settings, then the
    /// next launch opens there with that agent.
    @MainActor
    func testPickedInSettingsOpensThereWithThatAgent() throws {
        let app = makeApp()
        launch(app, landing: nil, extra: ["-loopdy.home.opens-chat", "YES"])
        let hero = app.buttons["agent.hero.name"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 25), "Nothing picked: today's start, the agent's chat")
        XCTAssertEqual(hero.label, "Avery Park", "The demo's default agent")

        openRootTab("tab.profile", in: app)
        settingsRow("settings.menu.chat", in: app).tap()
        let openOn = app.buttons["settings.landing.screen"].firstMatch
        XCTAssertTrue(openOn.waitForExistence(timeout: 5), "Open on leads Settings › Chat")
        XCTAssertTrue(openOn.label.contains("Last chat"), "Shows today's start until you pick: \(openOn.label)")
        openOn.tap()
        let feed = app.buttons["Feed"].firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Agents (multi)"].firstMatch.exists)
        feed.tap()
        XCTAssertTrue(openOn.label.contains("Feed"), openOn.label)

        let startWith = app.buttons["settings.landing.agent"].firstMatch
        XCTAssertTrue(startWith.waitForExistence(timeout: 5))
        XCTAssertTrue(startWith.label.contains("Automatic"), startWith.label)
        startWith.tap()
        let mina = app.buttons["Mina Shah"].firstMatch
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        mina.tap()
        XCTAssertTrue(startWith.label.contains("Mina Shah"), startWith.label)

        // Agents (multi) has no one agent to start with.
        openOn.tap()
        app.buttons["Agents (multi)"].firstMatch.tap()
        XCTAssertTrue(startWith.waitForNonExistence(timeout: 3), "No Start with for every computer's agents")
        openOn.tap()
        app.buttons["Feed"].firstMatch.tap()
        XCTAssertTrue(startWith.waitForExistence(timeout: 3))
        app.terminate()

        // The same test run keeps its saved settings across relaunches. The
        // Chat tab opens the agent's chat, as it does outside these tests.
        launch(app, landing: nil, extra: ["-loopdy.home.opens-chat", "YES"])
        XCTAssertTrue(element("board.feed", in: app).waitForExistence(timeout: 25), "Opens on Feed")
        XCTAssertTrue(app.buttons["tab.feed"].firstMatch.isSelected)
        app.buttons["tab.sessions"].firstMatch.tap()
        let homeHero = app.buttons["agent.hero.name"].firstMatch
        XCTAssertTrue(homeHero.waitForExistence(timeout: 10))
        XCTAssertEqual(homeHero.label, "Mina Shah", "Started with the picked agent")
    }

    /// A link that opens the app wins over the landing screen.
    @MainActor
    func testALinkOpeningTheAppWinsOverTheLandingScreen() throws {
        let app = makeApp()
        launch(app, landing: "feed")
        XCTAssertTrue(element("board.feed", in: app).waitForExistence(timeout: 25))
        app.terminate()

        // Cold launch through a widget-style link to Goals.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.home.landing", "projects"]
        app.open(URL(string: "loopdy://agent/goals")!)
        XCTAssertTrue(element("board.goals", in: app).waitForExistence(timeout: 25), "The link's screen opens")
        sleep(3)
        XCTAssertFalse(element("projects.screen", in: app).exists, "The landing screen doesn't cover the link")
        XCTAssertTrue(app.buttons["tab.goals"].firstMatch.isSelected)
    }

    @MainActor
    func testSettingsPickerLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["BIGHELP_LANDING_EVIDENCE"]
        for appearance in ["light", "dark"] {
            let app = makeApp()
            launch(app, landing: "goals", extra: ["-loopdy.demo.appearance", appearance])
            XCTAssertTrue(element("board.goals", in: app).waitForExistence(timeout: 25))
            app.buttons["tab.sessions"].firstMatch.tap()
            openRootTab("tab.profile", in: app)
            settingsRow("settings.menu.chat", in: app).tap()
            let openOn = app.buttons["settings.landing.screen"].firstMatch
            XCTAssertTrue(openOn.waitForExistence(timeout: 5))
            save(folder, "\(appearance)-1-chat-page", app)
            openOn.tap()
            XCTAssertTrue(app.buttons["Projects"].firstMatch.waitForExistence(timeout: 5))
            sleep(1)
            save(folder, "\(appearance)-2-open-on", app)
            app.buttons["Goals"].firstMatch.tap()
            let startWith = app.buttons["settings.landing.agent"].firstMatch
            XCTAssertTrue(startWith.waitForExistence(timeout: 5))
            startWith.tap()
            XCTAssertTrue(app.buttons["Automatic"].firstMatch.waitForExistence(timeout: 5))
            sleep(1)
            save(folder, "\(appearance)-3-start-with", app)
            app.buttons["Automatic"].firstMatch.tap()
            app.terminate()
        }
    }

    private func save(_ folder: String?, _ name: String, _ app: XCUIApplication) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
