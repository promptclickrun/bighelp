import XCTest

/// The bottom menu on the demo data: always open, each tab named; in a chat Chat is the lit tab and
/// tapping it stays put; a chat's Feed is its own agent's; Agents has New chat and no bottom menu;
/// and in the all-hosts view a chat has the menu too. BIGHELP_BOTTOM_MENU_EVIDENCE (TEST_RUNNER_…)
/// saves the screenshots.
final class BottomMenuUITests: BighelpUITestCase {
    @MainActor
    func testMenuNamesItsTabsAndChatsReachTheirAgentsBoard() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Opens on the agent's chat")
        let chat = app.buttons["tab.sessions"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5), "The whole bar, not one button")
        for name in ["Chat", "Feed", "Ideas", "Goals", "Files"] {
            XCTAssertTrue(app.staticTexts[name].exists, "\(name) is named under its icon")
        }
        save("chat", app)

        app.buttons["tab.ideas"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.ideas"].waitForExistence(timeout: 5), "Ideas, from the chat")
        save("ideas", app)
        chat.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "Back in the chat")
        XCTAssertTrue(chat.isSelected, "Chat is lit in a chat")
        XCTAssertFalse(app.buttons["tab.ideas"].isSelected, "Ideas isn't")
        chat.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 3), "Chat again stays in the chat")
        XCTAssertFalse(app.buttons["agents.new-chat"].exists, "Not thrown to Agents")
        save("chat-selected", app)

        // Agents: pick an agent first; New chat sits bottom right.
        openRootTab("tab.agents", in: app)
        let newChat = app.buttons["agents.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5), "Agents has the big New chat")
        XCTAssertFalse(app.buttons["tab.sessions"].exists, "No bottom menu on Agents")
        XCTAssertFalse(app.buttons["tab.feed"].exists)
        save("agents", app)
        newChat.tap()
        let started = app.textViews["chat.composer.text"].waitForExistence(timeout: 5)
            || app.navigationBars.matching(NSPredicate(format: "identifier CONTAINS[c] 'chat'")).firstMatch.exists
        XCTAssertTrue(started, "It starts a new chat (or opens the New chat picker)")
        save("agents-new-chat", app)
    }

    @MainActor
    func testAllHostsChatsHaveTheMenu() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES"]
        app.launch()
        let mina = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(mina.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["tab.feed"].exists, "All agents is a list of agents: no bottom menu")
        mina.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5))
        let feed = app.buttons["tab.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5), "An all-hosts chat has the bottom menu too")
        save("all-hosts-chat", app)
        feed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.feed"].waitForExistence(timeout: 5))
        save("all-hosts-feed", app)
        // Chat goes back to the chat you were in, not to All agents.
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5), "Back in the chat")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mina Shah"))
            .firstMatch.exists, "Mina's chat")
        XCTAssertFalse(app.descendants(matching: .any)["fleet.home"].exists)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_BOTTOM_MENU_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
