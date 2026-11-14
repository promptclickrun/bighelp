import XCTest

/// The computer in use's Sessions page (Chats › This computer) searches from the field at the
/// top, under the title, like every main screen, and a scroll puts the keyboard away.
/// Set BIGHELP_SESSIONS_SEARCH_SHOTS (TEST_RUNNER_…) to a folder to save screenshots.
final class SessionsSearchUITests: BighelpUITestCase {
    @MainActor
    func testOneComputerSessionsSearchFromTheTop() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openThisComputerSessions(in: app)

        let search = app.searchFields["Search chats"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Sessions has a search field without a pull")
        XCTAssertLessThan(search.frame.minY, app.windows.firstMatch.frame.height * 0.35, "It sits at the top")
        shot("one-computer-list", app)

        // The list scrolls to its last session (a pushed page: no bar under it).
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 { list.swipeUp() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let last = rows.element(boundBy: rows.count - 1)
        XCTAssertTrue(last.exists)
        shot("one-computer-end", app)
        for _ in 0..<6 { list.swipeDown() }

        // Matches the title and the text under it.
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        search.typeText("sentinel stays")
        XCTAssertTrue(text("Tool folder anchor regression", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(text("Finance", in: app).exists, "Other sessions step aside")
        let field = app.searchFields.firstMatch
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 1, "The field stays above the keyboard")
        shot("one-computer-searching", app)

        // Scrolling the results puts the keyboard away; the search stays.
        app.buttons["sessions.search.clear"].firstMatch.tap()
        field.tap()
        field.typeText("session")
        XCTAssertTrue(text("Direct session", in: app).waitForExistence(timeout: 5))
        // From the first result: with search at the top, later ones sit behind the keyboard.
        scrollResults(from: text("Direct session 1", in: app), in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "A scroll closes the keyboard")
        // The field scrolls with the list, like Mail's; back at the top, the search is still there.
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "session", "The search stays")
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
