import XCTest

/// Settings › Chat › Chat title puts the chat's title under the agent's name only when it's on.
final class ChatInfoUITests: BighelpUITestCase {
    @MainActor
    func testSessionTitleShowsOnlyWhenTurnedOn() {
        let off = launchHomeChat()
        XCTAssertFalse(off.descendants(matching: .any)["chat.identity.session-title"].firstMatch.waitForExistence(timeout: 3),
                       "Off by default")
        off.terminate()
        let on = launchHomeChat(extra: ["-bighelp.chat.shows-session-title", "YES"])
        XCTAssertTrue(on.descendants(matching: .any)["chat.identity.session-title"].firstMatch.waitForExistence(timeout: 8),
                      "The chat's title under the agent's name")
    }

    @MainActor
    private func launchHomeChat(extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["chat.identity"].waitForExistence(timeout: 20), "A one-on-one chat")
        return app
    }
}
