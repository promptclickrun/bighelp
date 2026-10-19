import XCTest

/// One-on-one chats reach Chat Info from ⋯ › This chat, and Settings › Chat › Session title puts
/// the chat's title under the agent's name only when it's on.
final class ChatInfoUITests: BighelpUITestCase {
    @MainActor
    func testOneOnOneChatOpensChatInfoFromTheMenu() {
        let app = launchHomeChat()
        XCTAssertTrue(openChatInfo(in: app), "⋯ › This chat › Chat info")
        XCTAssertTrue(app.descendants(matching: .any)["chat.session-info"].firstMatch.waitForExistence(timeout: 8),
                      "Chat Info opens for a one-on-one chat")
    }

    @MainActor
    func testSessionTitleShowsOnlyWhenTurnedOn() {
        let off = launchHomeChat()
        XCTAssertFalse(off.descendants(matching: .any)["agent.hero.session-title"].firstMatch.waitForExistence(timeout: 3),
                       "Off by default")
        off.terminate()
        let on = launchHomeChat(extra: ["-bighelp.chat.shows-session-title", "YES"])
        XCTAssertTrue(on.descendants(matching: .any)["agent.hero.session-title"].firstMatch.waitForExistence(timeout: 8),
                      "The chat's title under the agent's name")
    }

    @MainActor
    private func launchHomeChat(extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["agent.hero.name"].waitForExistence(timeout: 20), "A one-on-one chat")
        return app
    }
}
