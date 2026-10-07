import XCTest

/// Every screen in the bottom bar that has a search field puts it in the same place,
/// whichever tab you came from, and never on top of the bar. On one computer and with
/// all hosts showing, on demo data. Set BIGHELP_SEARCH_PLACEMENT_EVIDENCE (TEST_RUNNER_…)
/// to save screenshots.
final class SearchPlacementUITests: BighelpUITestCase {
    /// Agents, Scheduled tasks and Kanban in the bar beside Chat and Feed.
    private let layout = "{pinned=(agents,feed,scheduledTasks,kanban);menu=();}"
    private let searchedTabs = ["tab.sessions", "tab.agents", "tab.scheduled-tasks", "tab.kanban"]
    private let origins = ["tab.sessions", "tab.feed", "tab.agents", "tab.scheduled-tasks", "tab.kanban"]

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

    /// Goes to each searched tab from each other tab, and checks where the search field and
    /// the title land: the same place every time, and never on the bar.
    @MainActor private func audit(allHosts: Bool, homeOpensChat: Bool) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.home.opens-chat", homeOpensChat ? "YES" : "NO",
                               "-bighelp.app-layout", layout, "-bighelp.hosts.all-hosts", allHosts ? "YES" : "NO"]
        app.launch()
        let mode = (allHosts ? "all-hosts" : "one-host") + (homeOpensChat ? "-chat" : "-list")
        if allHosts {
            // All agents is the home: its list has no bottom bar. Its search must still stand clear.
            XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].firstMatch.waitForExistence(timeout: 20)
                          || app.searchFields.firstMatch.waitForExistence(timeout: 5))
            let search = visibleSearchField(in: app)
            print("SEARCH \(mode)-home: search \(search.map { "\($0.frame)" } ?? "none")")
            save("\(mode)-home", app)
            // The bar comes with an agent's own pages: open one.
            let agent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "fleet.agent.")).firstMatch
            if agent.waitForExistence(timeout: 5) { agent.tap() }
        }
        guard app.buttons["tab.agents"].waitForExistence(timeout: 20) else {
            XCTAssertFalse(!allHosts, "The bottom bar shows on one computer")
            return
        }
        var searches: [String: [String: CGRect?]] = [:]
        var titles: [String: [String: CGFloat]] = [:]
        for target in searchedTabs {
            for origin in origins where origin != target {
                guard tap(origin, in: app), tap(target, in: app) else { continue }
                let name = "\(mode)-\(target.dropFirst(4))-from-\(origin.dropFirst(4))"
                let search = visibleSearchField(in: app)
                let bar = app.descendants(matching: .any)["primary-navigation"].firstMatch
                let navigation = app.navigationBars.firstMatch
                print("SEARCH \(name): search \(search.map { "\($0.frame)" } ?? "none") bar \(bar.exists ? bar.frame : .zero) "
                      + "title bar \(navigation.exists ? navigation.frame : .zero)")
                save(name, app)
                searches[target, default: [:]][origin] = search?.frame
                if navigation.exists { titles[target, default: [:]][origin] = navigation.frame.height }
                guard let search, bar.exists else { continue }
                let overlaps = search.frame.maxY > bar.frame.minY && search.frame.minY < bar.frame.maxY
                XCTAssertFalse(overlaps, "\(name): the search field sits on the bottom bar")
                if search.frame.minY >= bar.frame.maxY - 1 {
                    XCTAssertGreaterThanOrEqual(search.frame.minY - bar.frame.maxY, 12,
                                                "\(name): the search field touches the bottom bar")
                }
            }
        }
        for (target, frames) in searches {
            let shown = frames.compactMapValues { $0 }
            XCTAssertTrue(shown.isEmpty || shown.count == frames.count,
                          "\(mode) \(target): the search field shows from some tabs only: \(frames)")
            guard let first = shown.values.first else { continue }
            for (origin, frame) in shown {
                XCTAssertEqual(frame.midY, first.midY, accuracy: 2,
                               "\(mode) \(target): the search field moves when you come from \(origin)")
            }
        }
        for (target, heights) in titles {
            guard let first = heights.values.first else { continue }
            for (origin, height) in heights {
                XCTAssertEqual(height, first, accuracy: 2,
                               "\(mode) \(target): the title changes size when you come from \(origin)")
            }
        }
    }

    /// Taps a bottom bar tab, when this screen's bar has it.
    @MainActor private func tap(_ tab: String, in app: XCUIApplication) -> Bool {
        let button = app.buttons[tab].firstMatch
        guard button.waitForExistence(timeout: 4), button.isHittable else { return false }
        button.tap()
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    /// The search field on screen, if any (a list's may be scrolled away until pulled down).
    @MainActor private func visibleSearchField(in app: XCUIApplication) -> XCUIElement? {
        app.searchFields.allElementsBoundByIndex.first { $0.exists && $0.frame.height > 0 && $0.isHittable }
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
