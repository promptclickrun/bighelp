import XCTest

/// Opening a chat that's already open (a notification, widget or link about it) goes
/// back to that chat instead of stacking a second copy: Back then leaves it.
final class ChatOpenOnceUITests: BighelpUITestCase {
    @MainActor
    func testOpeningTheOpenChatAgainKeepsOneCopy() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-start-chat"]
        app.launch()
        let back = app.buttons["chat.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "Simple Bot mode's chat has Back")

        // The chat on screen, opened again from outside.
        let chat = URL(string: "loopdy://chat/demo-finance")!
        app.open(chat)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 5),
                      "One Back leaves the chat: it was open once")

        // The chat under its bot's profile, opened from outside: back to that chat.
        app.open(chat)
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 5))
        app.open(chat)
        XCTAssertTrue(identity.waitForExistence(timeout: 5), "The chat comes back")
        Thread.sleep(forTimeInterval: 1.5)
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 5),
                      "Its profile went, and the chat was open once")
    }
}
