import XCTest

/// On iOS 26 a root list's search field runs along the bottom, just under the bottom
/// bar. Scheduled tasks keeps the same gap there as Sessions, on demo data. Set
/// BIGHELP_SEARCH_GAP_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class BottomSearchGapUITests: BighelpUITestCase {
    @MainActor
    func testScheduledTasksSearchClearsTheBarLikeSessions() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("The search field is at the top before iOS 26") }
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays",
                                "-bighelp.app-layout", "{pinned=(scheduledTasks,feed,files);menu=();}"]
        app.launch()
        let sessions = gap(below: "tab.sessions", in: app, name: "search-gap-sessions")
        let tasks = gap(below: "tab.scheduled-tasks", in: app, name: "search-gap-scheduled-tasks")
        print("Search gap: sessions \(sessions), scheduled tasks \(tasks)")
        XCTAssertGreaterThan(tasks, 4, "The search field and the bottom bar must not touch")
        XCTAssertEqual(tasks, sessions, accuracy: 1, "Scheduled tasks matches Sessions")
    }

    /// Space between the bottom search field and the bar, on this tab.
    @MainActor private func gap(below tab: String, in app: XCUIApplication, name: String) -> CGFloat {
        let button = app.buttons[tab].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), tab)
        button.tap()
        Thread.sleep(forTimeInterval: 1.2)
        let search = app.searchFields.firstMatch
        let bar = app.descendants(matching: .any)["primary-navigation"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "\(tab) has a search field")
        XCTAssertTrue(bar.exists)
        save(name, app)
        // Measured from the bar's bottom: Sessions' bar also holds the New chat button above it.
        return search.frame.minY - bar.frame.maxY
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SEARCH_GAP_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
