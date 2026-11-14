import XCTest

/// Vision Pro: ☰ › Kanban opens the board in its own glass window with all
/// five lanes. Pinch and drag a card to move it. Screenshots
/// work like `SpatialAvatarUITests` (BIGHELP_VISION_EVIDENCE plus a helper on
/// the Mac answering each "<name>.request" with `simctl io screenshot`).
final class KanbanVisionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKanbanOpensInItsOwnWindow() throws {
        let app = launch()
        openKanbanFromMenu(app)
        let window = app.descendants(matching: .any)["kanban.window"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Kanban opens its own window")
        XCTAssertTrue(app.buttons["home.drawer.open"].firstMatch.exists, "Bighelp's own window stays open")
        for lane in ["later", "ready", "working", "needsYou", "done"] {
            XCTAssertTrue(app.descendants(matching: .any)["kanban.lane.\(lane)"].firstMatch.waitForExistence(timeout: 10), lane)
        }
        save("kanban-window", app)
    }

    /// XCUITest can't touch a second window on Vision Pro, so this opens the
    /// same board inside bighelp's window to pinch-drag a card across lanes.
    @MainActor
    func testPinchDragMovesACardAcrossLanes() throws {
        let app = launch(extra: ["-test-kanban-main-window"])
        openKanbanFromMenu(app)
        XCTAssertTrue(app.descendants(matching: .any)["kanban.columns"].firstMatch.waitForExistence(timeout: 15))
        let card = app.descendants(matching: .any)["kanban.card.t_quotes"].firstMatch
        let done = app.descendants(matching: .any)["kanban.lane.done"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        save("kanban-inline", app)
        card.press(forDuration: 0.4, thenDragTo: done)
        XCTAssertTrue(done.descendants(matching: .any)["kanban.card.t_quotes"].firstMatch.waitForExistence(timeout: 8),
                      "A pinch-drag moves the card to another lane")
        save("kanban-dragged", app)

        // A pinch without moving opens the card.
        app.descendants(matching: .any)["kanban.card.t_budget"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["kanban.needs-you"].firstMatch.waitForExistence(timeout: 8))
        save("kanban-card", app)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra + ["-use-demo-fixtures", "-disable-demo-delays",
                                       "-loopdy.home.opens-chat", "NO", "-loopdy.settings.nerd-mode", "NO"]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    @MainActor
    private func openKanbanFromMenu(_ app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        // The menu offers Kanban once the host says it has it.
        let row = app.buttons["menu.kanban"].firstMatch
        let list = app.collectionViews.firstMatch
        let deadline = Date().addingTimeInterval(15)
        while !(row.exists && row.isHittable), Date() < deadline {
            if list.exists { list.swipeUp() } else { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "☰ offers Kanban")
        row.tap()
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VISION_EVIDENCE"] else { return }
        let base = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let shot = base.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: shot)
        FileManager.default.createFile(atPath: base.appendingPathComponent("\(name).request").path, contents: nil)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: shot.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
