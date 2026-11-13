import XCTest

/// Move to Project…, from a chat's ⋯ menu and from a chat's hold menu on Chats › This computer, on the demo
/// computer: the chat lands in the project picked, and the sheet and the list say so.
final class MoveChatToProjectUITests: BighelpUITestCase {
    @MainActor
    func testTheChatMenuMovesTheOpenChat() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 20))

        chatMenuItem("chat.move-project", in: app).tap()
        let home = app.buttons["chat.move-project.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 8), "The sheet lists the computer's projects")
        evidence("sheet")
        home.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 8), "The sheet closes once the move is confirmed")

        chatMenuItem("chat.move-project", in: app).tap()
        let moved = app.buttons["chat.move-project.home"].firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 8))
        XCTAssertEqual(moved.value as? String, "This chat is here", "The open chat knows its new project")
        XCTAssertNotEqual(app.buttons["chat.move-project.loopdy"].firstMatch.value as? String, "This chat is here")
        evidence("moved")
    }

    @MainActor
    func testAChatsHoldMenuMovesItIntoTheProjectsFolder() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.sessions.organizeByProjects", "YES"]
        app.launch()
        openThisComputerSessions(in: app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let row = rows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        let rowID = row.identifier

        row.press(forDuration: 1.2)
        let item = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'session.action.move-project.' OR label == %@", "Move to Project…")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "A chat's hold menu has Move to Project…")
        evidence("hold-menu")
        item.tap()
        let home = app.buttons["chat.move-project.home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 8))
        home.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 8))

        let folder = app.buttons["sessions.section-toggle.project:home"].firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8), "The chat's new project shows as a folder")
        let moved = app.buttons[rowID].firstMatch
        XCTAssertTrue(moved.waitForExistence(timeout: 5))
        let toggles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.section-toggle.'"))
            .allElementsBoundByIndex.map(\.frame.minY).sorted()
        let nextFolder = toggles.first { $0 > folder.frame.minY } ?? .greatestFiniteMagnitude
        XCTAssertGreaterThan(moved.frame.minY, folder.frame.minY, "The chat sits in Home's folder")
        XCTAssertLessThan(moved.frame.minY, nextFolder, "The chat sits in Home's folder")
        evidence("list-moved")
    }

    @MainActor
    private func evidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "move-chat-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
