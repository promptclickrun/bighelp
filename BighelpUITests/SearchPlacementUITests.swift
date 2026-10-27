import XCTest

/// Main screens look the same whichever tab you came from. The bottom bar never moves, and
/// each screen's search field is the first thing under its title, never down by the bar.
/// On one computer (Chat as the agent's chat, or the Sessions list) and with all hosts
/// showing, on demo data. Set BIGHELP_SEARCH_PLACEMENT_EVIDENCE (TEST_RUNNER_…) to save
/// screenshots.
final class SearchPlacementUITests: BighelpUITestCase {
    @MainActor
    func testAllHostsTasksHaveSearch() {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays",
                                "-bighelp.hosts.all-hosts", "YES", "-bighelp.app-layout", layout]
        app.launch()
        let agent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.agent.")).firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        agent.tap()
        let tasks = app.buttons["tab.scheduled-tasks"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 15))
        tasks.tap()
        let search = app.descendants(matching: .any)["scheduled-tasks.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "All hosts has the same task search as one computer")
        search.tap()
        search.typeText("No matching task 9327")
        XCTAssertTrue(app.staticTexts["No matching tasks"].waitForExistence(timeout: 3))
        XCTAssertTrue(search.exists, "An empty result must keep its search usable")
        app.buttons["scheduled-tasks.search.clear"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.task.")).firstMatch
            .waitForExistence(timeout: 5), "Clearing restores the tasks")
    }

    @MainActor
    func testPinnedKanbanKeepsTheAllHostsBarReachable() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES",
                               "-bighelp.app-layout", layout]
        app.launch()
        let agent = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(agent.waitForExistence(timeout: 15))
        agent.tap()
        XCTAssertTrue(tap("tab.kanban", in: app))
        XCTAssertTrue(app.buttons["tab.kanban"].isSelected, "Pinned Kanban is a root tab")
        XCTAssertTrue(tap("tab.scheduled-tasks", in: app), "Kanban must leave the bar reachable")
        XCTAssertTrue(app.descendants(matching: .any)["scheduled-tasks.search"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Agents, Scheduled tasks and Kanban in the bar beside Chat (three places at most).
    private let layout = "{pinned=(agents,scheduledTasks,kanban);menu=();}"
    private let searchedTabs = ["tab.sessions", "tab.agents", "tab.scheduled-tasks", "tab.kanban"]
    private let origins = ["tab.sessions", "tab.agents", "tab.scheduled-tasks", "tab.kanban"]
    private let searchIDs = ["tab.sessions": "sessions.search", "tab.agents": "agents.search",
                             "tab.scheduled-tasks": "scheduled-tasks.search", "tab.kanban": "kanban.search"]

    @MainActor
    func testSearchSitsInOnePlaceOnOneComputer() throws {
        try audit(allHosts: false, homeOpensChat: true)
    }

    @MainActor
    func testSearchSitsInOnePlaceWithTheSessionsList() throws {
        try audit(allHosts: false, homeOpensChat: false)
    }

    @MainActor
    func testSearchSitsInOnePlaceWithAllHosts() throws {
        try audit(allHosts: true, homeOpensChat: false)
    }

    @MainActor private func audit(allHosts: Bool, homeOpensChat: Bool) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.home.opens-chat", homeOpensChat ? "YES" : "NO",
                               "-bighelp.app-layout", layout, "-bighelp.hosts.all-hosts", allHosts ? "YES" : "NO"]
        app.launch()
        let mode = (allHosts ? "all-hosts" : "one-host") + (homeOpensChat ? "-chat" : "-list")
        if allHosts {
            // All agents is the home: its search is at the top too.
            let search = app.descendants(matching: .any)["fleet.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 20), "All agents has its search")
            XCTAssertLessThan(search.frame.minY, app.frame.height * 0.35, "All agents' search is at the top")
            save("\(mode)-home", app)
            let agent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.agent.")).firstMatch
            if agent.waitForExistence(timeout: 5) { agent.tap() }
        }
        guard app.buttons["tab.agents"].waitForExistence(timeout: 20) else {
            XCTFail("The configured bottom bar must show")
            return
        }
        var barFrame: CGRect?
        var searches: [String: [String: CGRect]] = [:]
        // All agents is intentionally a list without the bar. Audit the pinned pages
        // explicitly instead of entering that home and silently skipping the remaining tabs.
        let targets = allHosts ? searchedTabs.filter { $0 != "tab.sessions" } : searchedTabs
        let fromTabs = allHosts ? origins.filter { $0 != "tab.sessions" } : origins
        for target in targets {
            for origin in fromTabs where origin != target {
                guard tap(origin, in: app), tap(target, in: app) else {
                    XCTFail("Could not visit pinned tabs \(origin) → \(target)")
                    return
                }
                let name = "\(mode)-\(target.dropFirst(4))-from-\(origin.dropFirst(4))"
                // The tab row itself (the bar's container also holds Sessions' New chat button).
                let bar = app.buttons["tab.sessions"].firstMatch
                save(name, app)
                XCTAssertTrue(bar.exists, "\(name): the bottom bar")
                // The bar is in one place on every screen.
                if let barFrame {
                    XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 0.5, "\(name): the bottom bar moved")
                    XCTAssertEqual(bar.frame.height, barFrame.height, accuracy: 0.5, "\(name): the bottom bar changed")
                } else {
                    barFrame = bar.frame
                }
                // Nothing searches along the bottom any more.
                let low = app.searchFields.allElementsBoundByIndex.filter { $0.exists && $0.frame.minY > bar.frame.minY - 60 }
                XCTAssertTrue(low.isEmpty, "\(name): a search field sits down by the bar")
                // An agent's chat has no search; every list does, at the top.
                if target == "tab.sessions", app.textViews["chat.composer.text"].exists { continue }
                let searchID = allHosts && target == "tab.sessions" ? "fleet.search" : searchIDs[target]!
                let search = app.descendants(matching: .any)[searchID].firstMatch
                print("SEARCH \(name): search \(search.exists ? search.frame : .zero) bar \(bar.frame)")
                XCTAssertTrue(search.waitForExistence(timeout: 5), "\(name): its search field")
                XCTAssertLessThan(search.frame.minY, app.frame.height * 0.35, "\(name): the search field is at the top")
                searches[target, default: [:]][origin] = search.frame
            }
        }
        for (target, frames) in searches {
            guard let first = frames.values.first else { continue }
            for (origin, frame) in frames {
                XCTAssertEqual(frame.midY, first.midY, accuracy: 2,
                               "\(mode) \(target): the search field moves when you come from \(origin)")
            }
        }
    }

    /// Taps a bottom bar tab, when this screen's bar has it.
    @MainActor private func tap(_ tab: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons[tab].firstMatch
        guard button.waitForExistence(timeout: 4), button.isHittable else { return false }
        button.tap()
        let host = app.buttons["fleet.gate.host.Home Hermes"]
        if tab == "tab.kanban", host.waitForExistence(timeout: 1) { host.tap() }
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SEARCH_PLACEMENT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
