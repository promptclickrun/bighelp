import XCTest

/// One computer and all computers work alike: ☰ is one menu from anywhere, See all opens
/// the chat list, project folders fold, and All sessions has the same tags and filters, with
/// a computer's chip opening that computer's own Sessions screen without leaving all hosts.
/// Set BIGHELP_PARITY_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class SessionsParityUITests: BighelpUITestCase {
    @MainActor
    func testOneMenuFromAChatAndSeeAllOpensSessions() throws {
        let app = launch(allHosts: false)
        let menu = chatMenu(app)
        XCTAssertTrue(menu.waitForExistence(timeout: 15))

        // A chat's ⋯ has no second menu of its own.
        app.buttons["chat.options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.rename"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.workspace-menu"].exists, "Go to… is gone: ☰ is the menu")
        // Close it with a tap on the chat, away from the menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
        XCTAssertTrue(app.buttons["chat.rename"].firstMatch.waitForNonExistence(timeout: 3))

        menu.tap()
        let seeAll = app.buttons["menu.chats"].firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["quick-workspace.drawer"].exists)
        save("one-host-menu", app)
        seeAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].waitForExistence(timeout: 8),
                      "See all opens Sessions")
        save("one-host-sessions", app)
    }

    @MainActor
    func testProjectFolderFoldsItsChats() throws {
        let app = launch(allHosts: false, extra: ["-loopdy.sessions.organizeByProjects", "YES"])
        let menu = chatMenu(app)
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["menu.chats"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].waitForExistence(timeout: 8))

        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.section-toggle.'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8), "Group by Project shows project folders")
        // The chat right under the folder is the folder's own.
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let own = try XCTUnwrap(rows.allElementsBoundByIndex
            .filter { $0.frame.minY > folder.frame.minY }.min { $0.frame.minY < $1.frame.minY })
        let ownID = own.identifier
        let before = rows.allElementsBoundByIndex.map(\.identifier)
        save("folders-open", app)
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Collapsed")
        sleep(1)
        save("folder-folded", app)
        let after = rows.allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(after.contains(ownID),
                       "Its chats fold away with it: folder \(folder.identifier), \(ownID), before \(before), after \(after)")
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Expanded")
        XCTAssertTrue(app.descendants(matching: .any)[ownID].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCodexAndClaudeCodeChatsShowAndOpen() throws {
        let app = launch(allHosts: false)
        let menu = chatMenu(app)
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["menu.chats"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].waitForExistence(timeout: 8))

        let codex = app.buttons["sessions.other-app.Polish the Mac menus"]
        for _ in 0..<6 where !codex.exists { app.swipeUp() }
        XCTAssertTrue(codex.waitForExistence(timeout: 5), "Codex chats on the computer are listed")
        XCTAssertTrue(codex.label.contains("Codex"), codex.label)
        save("other-apps", app)
        codex.tap()
        let open = app.buttons["sessions.other-apps.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "A tap shows how it starts first")
        save("other-app-preview", app)
        open.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 8), "Open opens it as a chat")
    }

    @MainActor
    func testAllSessionsHasTagsFiltersAndAComputersOwnScreen() throws {
        let app = launch(allHosts: true)
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["menu.chats"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All sessions"].waitForExistence(timeout: 8), "See all opens All sessions")

        let tagged = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Started in'"))
        XCTAssertGreaterThan(tagged.count, 0, "Rows say where each chat started")
        let filters = app.buttons["fleet.chats.filters"]
        XCTAssertTrue(filters.exists, "The same filter menu as one computer")
        filters.tap()
        // Each filter is its own labeled choice, not one long list.
        let agentChoice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agent,'")).firstMatch
        XCTAssertTrue(agentChoice.waitForExistence(timeout: 3), "Agent, to filter by")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Started in,'")).firstMatch.exists,
                      "Started in, to filter by")
        save("all-sessions-filters", app)
        agentChoice.tap()
        let allAgents = app.buttons.matching(NSPredicate(format: "label == 'All agents' AND identifier != 'BackButton'"))
            .firstMatch
        XCTAssertTrue(allAgents.waitForExistence(timeout: 3), "Agents to filter by")
        save("all-sessions-filter-agent", app)
        allAgents.tap()
        XCTAssertTrue(agentChoice.waitForNonExistence(timeout: 3), "The menu closes")

        // A computer's chip opens its own Sessions screen (folders, agents), still in all hosts.
        app.buttons["fleet.filter.Home Hermes"].tap()
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.section-toggle.'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), "That computer's own Sessions screen, with its folders")
        XCTAssertTrue(app.buttons["fleet.filter.all"].exists, "Its chips stay, to go back to every computer")
        save("all-sessions-one-computer", app)

        // Back on All agents, ☰ still says all hosts, focused on that computer; Projects opens there.
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.exists { back.tap() } else { swipeBackFromLeadingEdge(in: app) }
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        save("all-agents-focused", app)
        menu.tap()
        XCTAssertEqual(app.buttons["menu.all-hosts"].label, "Show one host", "Still in all hosts")
        XCTAssertTrue(app.buttons["menu.hosts"].label.contains("Home Hermes"), app.buttons["menu.hosts"].label)
        let projects = app.buttons["menu.projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 3), "Projects is in the all-hosts menu")
        save("all-hosts-menu-focused", app)
        projects.tap()
        XCTAssertFalse(app.buttons["fleet.gate.host.Home Hermes"].waitForExistence(timeout: 2),
                       "The focused computer doesn't need asking")
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 8))
        // Projects is a screen people stay on: ☰ in the corner, no Back. ☰ leads to All agents.
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "Projects is a screen of its own")
        menu.tap()
        let allAgentsRow = app.buttons["menu.all-agents"]
        XCTAssertTrue(allAgentsRow.waitForExistence(timeout: 5))
        allAgentsRow.tap()
        let homeChip = app.buttons["fleet.filter.Home Hermes"]
        XCTAssertTrue(homeChip.waitForExistence(timeout: 8))
        XCTAssertTrue(homeChip.isSelected, "All agents shows the focused computer too")

        // Every computer again.
        app.buttons["fleet.filter.all"].tap()
        XCTAssertTrue(app.buttons["fleet.filter.all"].isSelected)
    }

    // MARK: Helpers

    @MainActor private func launch(allHosts: Bool, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-bighelp.hosts.all-hosts", allHosts ? "YES" : "NO",
                               "-loopdy.home.opens-chat", allHosts ? "NO" : "YES"] + extra
        app.launch()
        return app
    }

    /// ☰ in the chat header, or on a list.
    @MainActor private func chatMenu(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.menu", "home.drawer.open"])).firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PARITY_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
