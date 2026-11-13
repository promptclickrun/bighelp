import XCTest

/// Each bot's Files tab on its page is that bot's own folder (#518). On the demo data each bot has
/// its own; the next bot's page shows the next bot's files, and a file opens from it.
/// BIGHELP_AGENT_FILES_EVIDENCE (TEST_RUNNER_…) saves screenshots.
final class AgentFilesUITests: BighelpUITestCase {
    @MainActor
    func testSwitchingAgentsShowsEachAgentsOwnFiles() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "bots",
                                    "-loopdy.demo.appearance", appearance]
            app.launch()

            openFiles(of: "finance", named: "Avery Park", in: app)
            XCTAssertTrue(row("Notes.md", in: app).waitForExistence(timeout: 10), "Avery's own files")
            save("finance-\(appearance)", app)

            openFiles(of: "travel", named: "Mina Shah", in: app)
            let itinerary = row("Itinerary.md", in: app)
            XCTAssertTrue(itinerary.waitForExistence(timeout: 10), "Mina's own files")
            XCTAssertTrue(row("Notes.md", in: app).waitForNonExistence(timeout: 5), "Not Avery's")
            save("travel-\(appearance)", app)
            itinerary.tap()
            XCTAssertTrue(app.navigationBars["Itinerary.md"].waitForExistence(timeout: 10), "The file opens")
            save("travel-open-\(appearance)", app)
            app.buttons["Done"].firstMatch.tap()

            openFiles(of: "home", named: "Jordan Lee", in: app)
            XCTAssertTrue(row("Grocery list.txt", in: app).waitForExistence(timeout: 10), "Jordan's own files")
            XCTAssertTrue(row("Itinerary.md", in: app).waitForNonExistence(timeout: 5), "Not Mina's")
            save("home-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testWorkspaceFileSearchFilterAndSort() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "bots",
                                    "-loopdy.demo.appearance", appearance]
            app.launch()
            openFiles(of: "finance", named: "Avery Park", in: app)
            let search = app.descendants(matching: .any)["files.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            app.buttons["files.sort"].tap()
            app.buttons["Created"].tap()
            app.buttons["files.filter"].tap()
            app.buttons["Documents"].tap()
            save("workspace-filtered-\(appearance)", app)
            search.tap()
            search.typeText("no-such-file-12345")
            XCTAssertTrue(app.staticTexts["No matching files"].waitForExistence(timeout: 5))
            app.buttons["files.clear"].tap()
            XCTAssertTrue(row("Notes.md", in: app).waitForExistence(timeout: 5))
            save("workspace-files-\(appearance)", app)
            app.terminate()
        }
    }

    /// The same on a real Hermes with two agents or more, read only: no chats sent, no settings changed.
    /// Set BIGHELP_AGENT_FILES_HOST (as TEST_RUNNER_…) to an open host, e.g. 127.0.0.1:9121.
    @MainActor
    func testARealHostShowsEachAgentsOwnFiles() throws {
        guard let host = ProcessInfo.processInfo.environment["BIGHELP_AGENT_FILES_HOST"] else {
            throw XCTSkip("Set BIGHELP_AGENT_FILES_HOST")
        }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: host)
        showBots(in: app)
        // The primary bot's row carries no ID; the rest name theirs.
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                      "simple-bots.bot.", "simple-bots.pinned."))
        XCTAssertTrue(listed.firstMatch.waitForExistence(timeout: 30))
        let agents = listed.allElementsBoundByIndex.prefix(3).map {
            $0.identifier.replacingOccurrences(of: "simple-bots.bot.", with: "")
                .replacingOccurrences(of: "simple-bots.pinned.", with: "")
        }
        XCTAssertGreaterThanOrEqual(agents.count, 1, "The host has two agents or more: the primary and another")
        for agent in agents + [agents[0]] {
            openFiles(of: agent, named: nil, in: app)
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Opening"))
                .firstMatch.waitForNonExistence(timeout: 30), agent)
            XCTAssertFalse(app.staticTexts["Update the bighelp plugin to see files"].exists,
                           "\(agent): the plugin reads every agent's folder")
            let rows = app.buttons.matching(identifier: "simple-bots.files.item")
                .allElementsBoundByIndex.prefix(5).map(\.label)
            add(XCTAttachment(string: "\(agent): \(rows)"))
            save("real-host-\(agent)", app)
        }
    }

    /// Bots › the bot (its chat opens) › its pill › Files. `name` finds it when it is the primary bot.
    @MainActor
    private func openFiles(of botID: String, named name: String?, in app: XCUIApplication) {
        showBots(in: app)
        var predicate = NSPredicate(format: "identifier IN %@", ["simple-bots.bot.\(botID)", "simple-bots.pinned.\(botID)"])
        if let name {
            predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [predicate, NSPredicate(
                format: "identifier == %@ AND label BEGINSWITH %@", "simple-bots.primary", name)])
        }
        let bot = app.buttons.matching(predicate).firstMatch
        let home = app.descendants(matching: .any)["simple-bots.home"].firstMatch
        _ = bot.waitForExistence(timeout: 10)
        for _ in 0..<6 where !(bot.exists && bot.isHittable) { home.swipeUp() }
        XCTAssertTrue(bot.exists, "Bots lists \(botID)")
        guard bot.exists else { return }
        bot.tap()
        openBotPage(fromChatIn: app)
        let tab = app.buttons["simple-bots.profile.tab.files"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "The bot's page has Files")
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile.files"].firstMatch.waitForExistence(timeout: 10))
    }

    /// A file's row on the bot's Files tab, by the name it starts with.
    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
                                         "simple-bots.files.item", name)).firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AGENT_FILES_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
