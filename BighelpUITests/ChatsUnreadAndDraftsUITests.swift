import XCTest

/// The Chats list shows which chats have something new and which hold an unsent message (#862),
/// in light and dark and at a large text size; Mark Unread puts the dot back and reading the chat
/// clears it. Set BIGHELP_CHATS_UNREAD_SHOTS (TEST_RUNNER_…) to a folder to save screenshots.
final class ChatsUnreadAndDraftsUITests: BighelpUITestCase {
    @MainActor
    func testUnreadAndDraftRowsInEveryLook() throws {
        let looks: [(name: String, arguments: [String])] = [
            ("light", ["-loopdy.demo.appearance", "light"]),
            ("dark", ["-loopdy.demo.appearance", "dark"]),
            ("large-text", ["-loopdy.demo.appearance", "light",
                            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]),
        ]
        for look in looks {
            let app = launch(look.arguments)
            let travel = row("demo-travel", in: app)
            XCTAssertTrue(travel.waitForExistence(timeout: 10))
            XCTAssertTrue(travel.label.contains("Unread"), "\(look.name): \(travel.label)")
            let finance = row("demo-finance", in: app)
            XCTAssertFalse(finance.label.contains("Unread"), "\(look.name): \(finance.label)")
            shot(look.name, app)

            let draft = row("demo-session-2", in: app)
            scroll(to: draft, in: app)
            XCTAssertTrue(draft.label.contains("Draft"), "\(look.name): \(draft.label)")
            XCTAssertFalse(row("demo-session-1", in: app).label.contains("Draft"))
            shot(look.name + "-draft", app)
            app.terminate()
        }
    }

    @MainActor
    func testMarkUnreadThenReadingTheChatClearsIt() throws {
        let app = launch(["-loopdy.demo.appearance", "light"])
        let finance = row("demo-finance", in: app)
        XCTAssertTrue(finance.waitForExistence(timeout: 10))
        XCTAssertFalse(finance.label.contains("Unread"))

        finance.press(forDuration: 1.2)
        let markUnread = app.buttons["chats.action.unread.here/demo-finance"].firstMatch
        XCTAssertTrue(markUnread.waitForExistence(timeout: 5))
        XCTAssertEqual(markUnread.label, "Mark unread")
        markUnread.tap()
        XCTAssertTrue(waitForLabel(of: finance, containing: "Unread", true))
        shot("marked-unread", app)

        finance.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        goBackFromChat(in: app)
        XCTAssertTrue(finance.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: finance, containing: "Unread", false), "Reading the chat marks it read")
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "chats",
                               "-bighelp.hosts.all-hosts", "NO"] + arguments
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chats.inbox"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        chatRow(id, in: app)
    }

    /// Until the row sits in the middle of the screen, clear of the header and the bar.
    @MainActor
    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        let height = app.windows.firstMatch.frame.height
        for _ in 0..<8 where !(element.exists && element.frame.maxY < height * 0.75) {
            list.swipeUp(velocity: .slow)
        }
    }

    @MainActor
    private func waitForLabel(of element: XCUIElement, containing text: String, _ expected: Bool) -> Bool {
        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline {
            if element.exists, element.label.contains(text) == expected { return true }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CHATS_UNREAD_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
