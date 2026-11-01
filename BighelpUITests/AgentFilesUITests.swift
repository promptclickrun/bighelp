import XCTest

/// Files in the agent home is the selected agent's own folder (#518). On the demo data each agent has
/// its own; switching agents on Files shows the next agent's, and a file opens from it. Nerd Mode's
/// Artifacts stays the serving agent's. BIGHELP_AGENT_FILES_EVIDENCE (TEST_RUNNER_…) saves screenshots.
final class AgentFilesUITests: BighelpUITestCase {
    @MainActor
    func testSwitchingAgentsShowsEachAgentsOwnFiles() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            // Files lives in ☰ by default; pinned here so the bar holds it.
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                    "-bighelp.hosts.all-hosts", "NO", "-loopdy.demo.appearance", appearance,
                                    "-bighelp.app-layout", "{pinned=(feed,ideas,files);menu=();}"]
            app.launch()
            let files = app.buttons["tab.apps"]
            XCTAssertTrue(files.waitForExistence(timeout: 30), "The bottom bar holds Files")
            files.tap()
            XCTAssertTrue(app.descendants(matching: .any)["board.apps"].waitForExistence(timeout: 10))

            switchAgent(to: "finance", in: app)
            XCTAssertTrue(row("Notes.md", in: app).waitForExistence(timeout: 10), "Avery's own files")
            save("finance-\(appearance)", app)

            switchAgent(to: "travel", in: app)
            let itinerary = row("Itinerary.md", in: app)
            XCTAssertTrue(itinerary.waitForExistence(timeout: 10), "Mina's own files")
            XCTAssertTrue(row("Notes.md", in: app).waitForNonExistence(timeout: 5), "Not Avery's")
            save("travel-\(appearance)", app)
            itinerary.tap()
            XCTAssertTrue(app.navigationBars["Itinerary.md"].waitForExistence(timeout: 10), "The file opens")
            save("travel-open-\(appearance)", app)
            app.buttons["Done"].firstMatch.tap()

            switchAgent(to: "home", in: app)
            XCTAssertTrue(row("Grocery list.txt", in: app).waitForExistence(timeout: 10), "Jordan's own files")
            XCTAssertTrue(row("Itinerary.md", in: app).waitForNonExistence(timeout: 5), "Not Mina's")
            save("home-\(appearance)", app)

            // The host's own Artifacts reads the serving agent, whichever agent is selected.
            openRootDestination("workspace", sidebarIdentifier: "menu.hermes-tools", in: app)
            let artifacts = app.buttons["workspace.open.artifacts"]
            for _ in 0..<6 where !artifacts.isHittable { app.swipeUp() }
            artifacts.tap()
            XCTAssertTrue(row("Notes.md", in: app).waitForExistence(timeout: 10), "The serving agent's files")
            XCTAssertFalse(row("Grocery list.txt", in: app).exists)
            save("nerd-mode-artifacts-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testWorkspaceFileSearchFilterAndSort() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                    "-bighelp.hosts.all-hosts", "NO", "-loopdy.demo.appearance", appearance,
                                    "-bighelp.app-layout", "{pinned=(feed,ideas,files);menu=();}"]
            app.launch()
            XCTAssertTrue(app.buttons["tab.apps"].waitForExistence(timeout: 30))
            app.buttons["tab.apps"].tap()
            switchAgent(to: "finance", in: app)
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

    /// The same on a real Hermes with two agents or more, read only: no chats, no settings changed.
    /// Set BIGHELP_AGENT_FILES_HOST (as TEST_RUNNER_…) to an open host, e.g. 127.0.0.1:9121.
    @MainActor
    func testARealHostShowsEachAgentsOwnFiles() throws {
        guard let host = ProcessInfo.processInfo.environment["BIGHELP_AGENT_FILES_HOST"] else {
            throw XCTSkip("Set BIGHELP_AGENT_FILES_HOST")
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES", "-bighelp.app-layout", "{pinned=(feed,ideas,files);menu=();}"]
        app.launch()
        try onboardOpenHost(app, address: host)
        let files = app.buttons["tab.apps"]
        XCTAssertTrue(files.waitForExistence(timeout: 30), "The bottom bar holds Files")
        files.tap()
        app.buttons["agent.hero.name"].firstMatch.tap()
        let listed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agent.switcher.agent."))
        XCTAssertTrue(listed.firstMatch.waitForExistence(timeout: 10))
        let agents = listed.allElementsBoundByIndex.prefix(3)
            .map { $0.identifier.replacingOccurrences(of: "agent.switcher.agent.", with: "") }
        XCTAssertGreaterThanOrEqual(agents.count, 2, "The host has two agents or more")
        for agent in agents + [agents[0]] {
            switchAgent(to: agent, in: app)
            XCTAssertTrue(app.staticTexts["Finding the workspace…"].waitForNonExistence(timeout: 30), agent)
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Plugin version"))
                .firstMatch.exists, "\(agent): the plugin reads every agent's folder")
            let rows = app.buttons.matching(NSPredicate(format: "label MATCHES %@", ".+, .+, Changed .+"))
                .allElementsBoundByIndex.prefix(5).map(\.label)
            add(XCTAttachment(string: "\(agent): \(rows)"))
            save("real-host-\(agent)", app)
        }
    }

    @MainActor
    private func switchAgent(to agentID: String, in app: XCUIApplication) {
        let agent = app.buttons["agent.switcher.agent.\(agentID)"]
        if !agent.exists { app.buttons["agent.hero.name"].firstMatch.tap() }
        XCTAssertTrue(agent.waitForExistence(timeout: 5), "The switcher lists \(agentID)")
        agent.tap()
        XCTAssertTrue(agent.waitForNonExistence(timeout: 5))
    }

    /// A file's row reads "name, path in the folder, when it changed".
    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
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
