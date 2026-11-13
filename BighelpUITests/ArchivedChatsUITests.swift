import XCTest

/// Archived Chats on the demo's rows: each row's ••• holds Restore and Delete, Delete asks first,
/// and a chat Hermes won't delete says why on its own row.
final class ArchivedChatsUITests: BighelpUITestCase {
    @MainActor
    func testDeleteAsksFirstAndARefusalStaysOnItsRow() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        // Chats › More › Archived opens Settings › Chat, which lists Archived chats.
        showChats(in: app)
        let more = app.buttons["chats.more.archived"].firstMatch
        let inbox = app.descendants(matching: .any)["chats.inbox"].firstMatch
        for _ in 0..<20 where !(more.exists && more.isHittable) { inbox.swipeUp(velocity: .fast) }
        XCTAssertTrue(more.exists && more.isHittable, "Archived is at the end of Chats")
        more.tap()
        let archived = app.buttons["simple-bots.settings.archived"].firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 10))
        for _ in 0..<6 where !archived.isHittable { app.swipeUp() }
        archived.tap()

        let deletedChat = "travel/demo-archived-lisbon"
        let row = app.buttons["archived-chats.chat.\(deletedChat)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        attach(app, "list")

        // Cancel keeps the chat.
        openDelete(deletedChat, in: app)
        attach(app, "confirm")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists, "Cancel keeps the chat")

        openDelete(deletedChat, in: app)
        app.buttons["archived-chats.delete-confirm"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "The chat leaves the list")

        // Still open on its gateway: the reason is on that row.
        let heldOpen = "finance/demo-archived-garage"
        openDelete(heldOpen, in: app)
        app.buttons["archived-chats.delete-confirm"].firstMatch.tap()
        let failure = app.descendants(matching: .any)["archived-chats.failure.\(heldOpen)"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["archived-chats.chat.\(heldOpen)"].exists, "The refused chat stays")
        XCTAssertFalse(app.staticTexts["archived-chats.error"].exists, "Nothing shows above the list")
        attach(app, "refused")
    }

    @MainActor
    private func openDelete(_ chat: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["archived-chats.more.\(chat)"].tap()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), file: file, line: line)
        attach(app, "menu")
        delete.tap()
        XCTAssertTrue(app.buttons["archived-chats.delete-confirm"].firstMatch.waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "archived-chats-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
