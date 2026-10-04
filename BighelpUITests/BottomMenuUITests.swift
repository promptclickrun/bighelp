import XCTest

/// The bottom menu on the demo data: it starts as one button that opens into Chat, Feed, Ideas,
/// Goals and Apps; a chat's Feed is its own agent's; Agents has New chat and no bottom menu; and
/// in the all-hosts view a chat has the menu too. BIGHELP_BOTTOM_MENU_EVIDENCE (TEST_RUNNER_…)
/// saves the screenshots.
final class BottomMenuUITests: BighelpUITestCase {
    @MainActor
    func testCollapsedMenuOpensAndChatsReachTheirAgentsBoard() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-bighelp.tabbar.starts-collapsed", "YES", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Opens on the agent's chat")
        let expand = app.buttons["primary-navigation.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "One button, not the whole bar")
        XCTAssertFalse(app.buttons["tab.feed"].exists)
        save("collapsed-chat", app)

        expand.tap()
        let feed = app.buttons["tab.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 3), "It opens into the bar")
        XCTAssertTrue(app.buttons["tab.ideas"].exists && app.buttons["tab.goals"].exists)
        save("expanded-chat", app)
        feed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.feed"].waitForExistence(timeout: 5), "Feed, from the chat")
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "It folds back after a pick")
        save("feed-collapsed", app)

        // Agents: pick an agent first; New chat sits bottom right.
        openRootTab("tab.agents", in: app)
        let newChat = app.buttons["agents.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5), "Agents has the big New chat")
        XCTAssertFalse(expand.exists, "No bottom menu on Agents")
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
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES",
                               "-bighelp.tabbar.starts-collapsed", "NO"]
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
