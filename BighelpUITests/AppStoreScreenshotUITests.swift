import XCTest

/// Opt-in: the App Store screenshot set, taken from the real app on a real
/// Hermes host (Scripts/AppStoreScreenshotHost.py), not demo fixtures. The
/// agents really read files, render cards, post to the board and schedule
/// jobs. Run Scripts/AppStoreScreenshots.sh, which starts the host, overrides
/// the status bar to 9:41 and sets these (TEST_RUNNER_…):
/// - BIGHELP_STORE_SCREENSHOTS: the output folder
/// - BIGHELP_STORE_HOST: the host's address
/// - BIGHELP_STORE_TZ: the host's time zone, so chat times read just before 9:41
final class AppStoreScreenshotUITests: BighelpUITestCase {
    private var folder = ""
    private var prefix = "iphone"

    /// Connects, has each agent do one real job, then captures the screens.
    @MainActor
    func testCaptureStoreScreenshots() throws {
        let app = try launch()
        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        sleep(1)
        save("10-connect", app)
        address.tap()
        address.typeText(try XCTUnwrap(environment("BIGHELP_STORE_HOST")))
        // A friendly name, as someone would give their computer.
        app.buttons["More options"].firstMatch.tap()
        let name = app.textFields["host-setup.name"]
        if name.waitForExistence(timeout: 3) {
            name.tap()
            name.typeText("Home Mac")
        }
        // During onboarding the bottom button reports the screen's identifier.
        app.buttons.matching(NSPredicate(format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch.tap()
        let next = app.buttons.matching(NSPredicate(format: "identifier IN %@ AND (label == %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], "Start chatting", "Let")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()

        // Juno, the everyday agent, opens first.
        try ask("Put this week's highlights on my Feed, and keep track of my goals.",
                until: "two ideas waiting", in: app)
        try newChat(in: app)
        try ask("Every weekday at 7:30, send me a short morning brief: weather, my calendar, and anything due.",
                until: "morning brief is scheduled", in: app)
        save("05-automation", app)

        openTab("tab.feed", in: app)
        save("03-feed", app)
        openTab("tab.goals", in: app)
        save("04-goals", app)
        openTab("tab.ideas", in: app)
        save("08-ideas", app)

        try openAgent("penny", in: app)
        try ask("Where did my money go in September? The statement is in Documents/Money.",
                until: "dining budget", in: app)
        try expectCard("September spending", chat: "September spending", in: app)
        scrollToCard(in: app, by: 0)
        save("01-spending", app)

        try openAgent("atlas", in: app)
        try ask("We fly to Lisbon on the 9th. Can you turn my trip notes into a packing list?",
                until: "reminder the night before", in: app)
        try expectCard("Lisbon packing list", chat: "Lisbon packing list", in: app)
        scrollToCard(in: app, by: 0)
        save("02-packing", app)

        openMenu(in: app)
        save("06-menu", app)
        tapMenuRow("menu.kanban", in: app)
        sleep(3)
        save("07-kanban", app)
        goBack(app)
        openMenu(in: app)
        tapMenuRow("menu.scheduled-tasks", in: app)
        sleep(3)
        save("09-scheduled", app)
    }

    // MARK: Steps

    @MainActor
    private func launch() throws -> XCUIApplication {
        guard let output = environment("BIGHELP_STORE_SCREENSHOTS"), environment("BIGHELP_STORE_HOST") != nil else {
            throw XCTSkip("Run Scripts/AppStoreScreenshots.sh to capture the App Store set.")
        }
        folder = output
        prefix = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        addUIInterruptionMonitor(withDescription: "System prompts") { dialog in
            for label in ["Not Now", "Don’t Allow", "Don't Allow", "Allow"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        if let zone = environment("BIGHELP_STORE_TZ") { app.launchEnvironment["TZ"] = zone }
        app.launch()
        return app
    }

    @MainActor
    private func ask(_ message: String, until reply: String, in app: XCUIApplication) throws {
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The chat is open")
        composer.tap()
        composer.typeText(message)
        app.buttons["chat.send"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", reply)).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 120), "The agent answered: \(reply)")
        // The turn settles and Hermes's saved history replaces the live reply.
        let stop = app.buttons["chat.stop"]
        let ended = NSPredicate { _, _ in !stop.exists }
        wait(for: [expectation(for: ended, evaluatedWith: nil)], timeout: 60)
        sleep(3)
        BighelpKeyboardDismissal.dismiss(in: app)
    }

    @MainActor
    private func newChat(in app: XCUIApplication) throws {
        let new = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["chat.new-chat", "chat.home.new-chat", "root.new-chat"])).firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()
        confirmNewChatPicker(in: app)
        sleep(2)
    }

    @MainActor
    private func openAgent(_ id: String, in app: XCUIApplication) throws {
        openMenu(in: app)
        tapMenuRow("menu.agents", in: app)
        let row = app.buttons["agent.\(id)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(id) is in Agents")
        row.tap()
        sleep(2)
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20), "\(id)'s chat opens")
    }

    @MainActor
    private func openMenu(in app: XCUIApplication) {
        let menu = [app.buttons["home.drawer.open"].firstMatch, app.buttons["chat.menu"].firstMatch]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let button = menu.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                break
            }
            // The board tabs have no ☰; it's on the chat tab and pushed screens.
            let chatTab = app.buttons["tab.sessions"].firstMatch
            if chatTab.exists, chatTab.isHittable { chatTab.tap() } else { goBack(app) }
            sleep(1)
        }
        _ = app.descendants(matching: .any)["navigation.menu"].waitForExistence(timeout: 10)
        sleep(1)
    }

    @MainActor
    private func tapMenuRow(_ identifier: String, in app: XCUIApplication) {
        let row = app.buttons[identifier].firstMatch
        let list = app.descendants(matching: .any)["navigation.menu"].firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), identifier)
        row.tap()
        sleep(2)
    }

    @MainActor
    private func openTab(_ identifier: String, in app: XCUIApplication) {
        openRootTab(identifier, in: app, timeout: 15)
        sleep(3)
    }

    /// The reply's card, reopening the chat from ☰ once if the card hasn't drawn.
    @MainActor
    private func expectCard(_ title: String, chat: String, in app: XCUIApplication) throws {
        let card = app.staticTexts[title].firstMatch
        if card.waitForExistence(timeout: 10) { return }
        openMenu(in: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", chat)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(chat) is in Recent chats")
        row.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The \(title) card shows")
    }

    /// Brings the agent's card fully into view, with its reply above it:
    /// the chat opens at its newest line, so drag down by a share of the screen.
    @MainActor
    private func scrollToCard(in app: XCUIApplication, by share: CGFloat) {
        if share > 0 {
            let window = app.windows.firstMatch
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4 + share))
            from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        sleep(2)
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        // Chats have ☰, not Back: leave them with an edge swipe.
        if app.buttons["chat.menu"].firstMatch.exists {
            swipeBackFromLeadingEdge(in: app); sleep(1); return
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable { back.tap(); sleep(1) }
    }

    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(prefix)-\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }
}

private enum BighelpKeyboardDismissal {
    @MainActor static func dismiss(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        app.swipeDown()
    }
}
