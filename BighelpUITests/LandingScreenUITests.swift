import XCTest

/// Settings › Chat › Opens on: a choice saved before the one home lands on the place that holds it
/// now, a link that opens the app wins over it, and the picker. Demo data. Set
/// BIGHELP_LANDING_EVIDENCE (TEST_RUNNER_BIGHELP_LANDING_EVIDENCE) to a folder to save the picker in
/// light and dark. Each new choice's own landing is `HomeShellUITests`'.
final class LandingScreenUITests: BighelpUITestCase {
    private func launch(_ app: XCUIApplication, landing: String, extra: [String] = []) {
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.home.landing", landing] + extra
        app.launch()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Opens on as the old shell saved it: each screen opens the place that holds it now, with no chat.
    @MainActor
    func testAChoiceSavedBeforeOpensOnThePlaceThatHoldsItNow() throws {
        let app = makeApp()
        let screens: [(landing: String, identifier: String)] = [
            ("feed", "today.home"),
            ("goals", "today.home"),
            ("projects", "work.screen"),
            ("kanban", "work.screen"),
            ("agents", "simple-bots.home"),
            ("all-agents", "simple-bots.home"),
            ("last-chat", "chats.inbox"),
            ("sessions", "chats.inbox"),
        ]
        for screen in screens {
            launch(app, landing: screen.landing)
            XCTAssertTrue(element(screen.identifier, in: app).waitForExistence(timeout: 25),
                          "\(screen.landing) opens on \(screen.identifier)")
            XCTAssertFalse(app.textViews["chat.composer.text"].exists, "\(screen.landing): no chat opens by itself")
            app.terminate()
        }
    }

    /// The real controls: Opens on picks a place, and Today or Work asks which view the first tab shows.
    @MainActor
    func testOpensOnPicksAPlaceAndTheFirstTabsView() throws {
        let app = makeApp()
        launch(app, landing: "chats")
        XCTAssertTrue(element("chats.inbox", in: app).waitForExistence(timeout: 25))

        openSettings(in: app)
        settingsRow("settings.menu.chat", in: app).tap()
        let openOn = app.buttons["settings.landing.screen"].firstMatch
        XCTAssertTrue(openOn.waitForExistence(timeout: 5), "Opens on leads Settings › Chat")
        XCTAssertTrue(openOn.label.contains("Chats"), "Shows where this launch opened: \(openOn.label)")
        let firstTab = app.buttons["settings.landing.view"].firstMatch
        XCTAssertFalse(firstTab.exists, "Bots and Chats name the first tab's view themselves")

        openOn.tap()
        let today = app.buttons["Today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Work"].firstMatch.exists)
        today.tap()
        XCTAssertTrue(openOn.label.contains("Today"), openOn.label)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 3), "Today asks which view the first tab shows")
        firstTab.tap()
        let bots = app.buttons["Bots"].firstMatch
        XCTAssertTrue(bots.waitForExistence(timeout: 5))
        bots.tap()
        XCTAssertTrue(firstTab.label.contains("Bots"), firstTab.label)

        openOn.tap()
        app.buttons["Chats"].firstMatch.tap()
        XCTAssertTrue(firstTab.waitForNonExistence(timeout: 3), "Back to Chats, the row goes")
        app.terminate()
    }

    /// A link that opens the app wins over the landing screen.
    @MainActor
    func testALinkOpeningTheAppWinsOverTheLandingScreen() throws {
        let app = makeApp()
        launch(app, landing: "today")
        XCTAssertTrue(element("today.home", in: app).waitForExistence(timeout: 25))
        app.terminate()

        // Cold launch through a widget-style link to Goals: every bot's Goals over Today.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.home.landing", "work"]
        app.open(URL(string: "loopdy://agent/goals")!)
        let board = element("today.board-page", in: app)
        XCTAssertTrue(board.waitForExistence(timeout: 25), "The link's screen opens")
        sleep(3)
        XCTAssertTrue(board.exists, "The landing screen doesn't cover the link")
        let work = element("work.screen", in: app)
        XCTAssertFalse(work.exists && work.isHittable, "Work, the landing, isn't on top")
    }

    @MainActor
    func testSettingsPickerLightAndDark() throws {
        let folder = ProcessInfo.processInfo.environment["BIGHELP_LANDING_EVIDENCE"]
        for appearance in ["light", "dark"] {
            let app = makeApp()
            launch(app, landing: "today", extra: ["-loopdy.demo.appearance", appearance])
            XCTAssertTrue(element("today.home", in: app).waitForExistence(timeout: 25))
            openSettings(in: app)
            settingsRow("settings.menu.chat", in: app).tap()
            let openOn = app.buttons["settings.landing.screen"].firstMatch
            XCTAssertTrue(openOn.waitForExistence(timeout: 5))
            save(folder, "\(appearance)-1-chat-page", app)
            openOn.tap()
            XCTAssertTrue(app.buttons["Work"].firstMatch.waitForExistence(timeout: 5))
            sleep(1)
            save(folder, "\(appearance)-2-open-on", app)
            app.buttons["Today"].firstMatch.tap()
            let firstTab = app.buttons["settings.landing.view"].firstMatch
            XCTAssertTrue(firstTab.waitForExistence(timeout: 5))
            firstTab.tap()
            XCTAssertTrue(app.buttons["Chats"].firstMatch.waitForExistence(timeout: 5))
            sleep(1)
            save(folder, "\(appearance)-3-first-tab", app)
            app.buttons["Chats"].firstMatch.tap()
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
