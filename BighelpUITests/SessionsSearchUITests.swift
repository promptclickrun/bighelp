import XCTest

/// Sessions on one computer and All sessions on every host search from the
/// glass bar along the bottom, like All agents. The bar never covers the last
/// session, and a scroll puts the keyboard away.
/// Set BIGHELP_SESSIONS_SEARCH_SHOTS (TEST_RUNNER_…) to a folder to save screenshots.
final class SessionsSearchUITests: BighelpUITestCase {
    @MainActor
    func testOneComputerSessionsSearchFromTheBottom() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].firstMatch.waitForExistence(timeout: 15))

        let search = app.searchFields["Search sessions"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Sessions has a search bar without a pull")
        XCTAssertGreaterThan(search.frame.minY, app.windows.firstMatch.frame.height * 0.7, "It sits at the bottom")
        shot("one-computer-list", app)

        // The last session scrolls clear of the search bar and the tab bar.
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 { list.swipeUp() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let last = rows.element(boundBy: rows.count - 1)
        XCTAssertTrue(last.exists)
        XCTAssertLessThanOrEqual(last.frame.maxY, search.frame.minY + 1, "The search bar doesn't cover the last session")
        let feed = app.buttons["tab.feed"].firstMatch
        if feed.exists {
            XCTAssertLessThanOrEqual(last.frame.maxY, feed.frame.minY + 1, "The tab bar doesn't cover the last session")
        }
        shot("one-computer-end", app)

        // Matches the title and the text under it.
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        search.typeText("sentinel stays")
        XCTAssertTrue(text("Tool folder anchor regression", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(text("Finance", in: app).exists, "Other sessions step aside")
        let field = app.searchFields.firstMatch
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "The bar rides above the keyboard")
        shot("one-computer-searching", app)

        // Scrolling the results puts the keyboard away; the search stays.
        field.buttons["Clear text"].firstMatch.tap()
        field.typeText("session")
        XCTAssertTrue(text("Direct session", in: app).waitForExistence(timeout: 5))
        scrollResults(from: text("Direct session 3", in: app), in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A scroll closes the keyboard")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "session", "The search stays")
    }

    @MainActor
    func testAllHostsSessionsSearchFromTheBottom() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["menu.all-hosts"].waitForExistence(timeout: 5))
        app.buttons["menu.all-hosts"].tap()
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5))
        menu.tap()
        let seeAll = app.buttons["menu.chats"].firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        seeAll.tap()
        XCTAssertTrue(app.navigationBars["All sessions"].waitForExistence(timeout: 5))

        let search = app.searchFields["Search sessions"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "All sessions has the search bar")
        XCTAssertGreaterThan(search.frame.minY, app.windows.firstMatch.frame.height * 0.7, "It sits at the bottom")
        XCTAssertTrue(text("Pull request review", in: app).waitForExistence(timeout: 10))
        shot("all-hosts-list", app)

        let list = app.collectionViews.firstMatch
        for _ in 0..<6 { list.swipeUp() }
        let rows = list.buttons
        let last = rows.element(boundBy: rows.count - 1)
        XCTAssertLessThanOrEqual(last.frame.maxY, search.frame.minY + 1, "The search bar doesn't cover the last session")

        // The preview text matches too, on another host's session.
        search.tap()
        search.typeText("competitors")
        XCTAssertTrue(text("Market scan", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(text("Pull request review", in: app).exists, "Other sessions step aside")
        shot("all-hosts-searching", app)
        scrollResults(from: text("Market scan", in: app), in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A scroll closes the keyboard")

        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("zzz")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No Results")).firstMatch
            .waitForExistence(timeout: 5), "No match says so")
    }

    /// A finger drag up the results, starting on a row.
    @MainActor
    private func scrollResults(from row: XCUIElement, in app: XCUIApplication) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
    }

    @MainActor
    private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SESSIONS_SEARCH_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
