import XCTest

/// Sessions on demo data: each chat shows where it started, and Started in shows chats from one
/// place. BIGHELP_SESSION_ORIGIN_SHOTS (TEST_RUNNER_…) names a folder for screenshots.
final class SessionOriginUITests: BighelpUITestCase {
    @MainActor
    func testChatsShowWhereTheyStartedAndFilterByIt() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openRootTab("tab.sessions", in: app)
        let telegram = row(containing: "Started in Telegram", in: app)
        XCTAssertTrue(telegram.waitForExistence(timeout: 15), "A chat from Telegram says so")
        save("sessions-origin-tags", app)

        let filters = app.descendants(matching: .any).matching(identifier: "sessions.filters").firstMatch
        XCTAssertTrue(filters.waitForExistence(timeout: 10))
        filters.tap()
        // In the filter menu the choices are items of their own; in the list's filters, a menu.
        let choice = app.buttons["Telegram"].firstMatch
        if !choice.waitForExistence(timeout: 5) {
            let origin = app.buttons["sessions.filter.origin"].firstMatch
            XCTAssertTrue(origin.waitForExistence(timeout: 5))
            origin.tap()
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        XCTAssertTrue(row(containing: "Started in Telegram", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row(containing: "Started in Hermes Desktop", in: app).exists, "Other places are filtered out")
        save("sessions-origin-filtered", app)
    }

    @MainActor
    private func row(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                             "session.row.", text)).firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SESSION_ORIGIN_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
