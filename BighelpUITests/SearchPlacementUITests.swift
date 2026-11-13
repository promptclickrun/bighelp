import XCTest

/// Main screens keep their search where people look for it. The home's bar never moves between
/// Bots, Chats, Today and Work, nothing searches down by it, and each list's search field is the
/// first thing under its title: Chats, and Work's Schedules and Tasks. On demo data. Set
/// BIGHELP_SEARCH_PLACEMENT_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class SearchPlacementUITests: BighelpUITestCase {
    @MainActor
    func testTheBarNeverMovesAndSearchSitsAtTheTop() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "chats"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chats.inbox"].firstMatch.waitForExistence(timeout: 20))

        // The bar is in one place on every root.
        var barFrame: CGRect?
        for (door, name) in [("home.switch.bots", "bots"), ("home.switch.chats", "chats"),
                             ("home.tab.today", "today"), ("home.tab.work", "work")] {
            if name == "bots" || name == "chats" { app.buttons["home.tab.conversations"].firstMatch.tap() }
            app.buttons[door].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1.2)
            let bar = app.buttons["home.tab.conversations"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(name): the bar")
            save("bar-\(name)", app)
            if let barFrame {
                XCTAssertEqual(bar.frame.minY, barFrame.minY, accuracy: 0.5, "\(name): the bar moved")
                XCTAssertEqual(bar.frame.height, barFrame.height, accuracy: 0.5, "\(name): the bar changed")
            } else {
                barFrame = bar.frame
            }
            // Nothing searches along the bottom.
            let low = app.searchFields.allElementsBoundByIndex.filter { $0.exists && $0.frame.minY > bar.frame.minY - 60 }
            XCTAssertTrue(low.isEmpty, "\(name): a search field sits down by the bar")
        }

        // Chats: its search is the first row.
        app.buttons["home.tab.conversations"].firstMatch.tap()
        app.buttons["home.switch.chats"].firstMatch.tap()
        expectSearchAtTop("chats.search", name: "chats", in: app)

        // Work's pushed lists: Schedules and Tasks.
        for (door, searchID) in [("schedules", "scheduled-tasks.search"), ("tasks", "kanban.search")] {
            openWorkDoor(door, in: app)
            expectSearchAtTop(searchID, name: door, in: app)
            leavePushedPage(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["work.screen"].firstMatch.waitForExistence(timeout: 10),
                          "Back returns to Work")
        }
    }

    @MainActor private func expectSearchAtTop(_ identifier: String, name: String, in app: XCUIApplication) {
        let search = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "\(name): its search field")
        print("SEARCH \(name): \(search.exists ? search.frame : .zero)")
        XCTAssertLessThan(search.frame.minY, app.frame.height * 0.35, "\(name): the search field is at the top")
        save("search-\(name)", app)
    }

    /// The page's own Back, else the navigation bar's.
    @MainActor private func leavePushedPage(in app: XCUIApplication) {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists, back.isHittable { back.tap(); return }
        let bar = app.navigationBars.buttons.firstMatch
        if bar.waitForExistence(timeout: 5) { bar.tap() }
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
