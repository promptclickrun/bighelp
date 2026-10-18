import XCTest

/// The Bots widget opens bighelp with a link naming a bot and its gateway. On the demo
/// data: Home Hermes is the demo's own computer, and Mina Shah (`travel`) one of its bots.
final class BotsWidgetUITests: BighelpUITestCase {
    private static let link = URL(string: "loopdy://agent-chat?agent=travel&host=0D0D0D0D-0000-4000-8000-000000000001")!

    /// Simple Bot mode, bighelp in the background: the bot's chat, with Back to the bots.
    @MainActor
    func testABotOpensItsChatInSimpleBotMode() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.open(Self.link)
        expectChat(with: "Mina Shah", in: app)
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 5))
    }

    /// bighelp closed: the tap starts it and opens the bot's chat once the computer answers.
    @MainActor
    func testABotOpensItsChatWhenBighelpWasClosed() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.terminate()
        app.open(Self.link)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        expectChat(with: "Mina Shah", in: app)
    }

    @MainActor
    private func expectChat(with name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let opened = app.textViews["chat.composer.text"].waitForExistence(timeout: 20)
        let alert = app.alerts.firstMatch
        XCTAssertFalse(alert.exists, alert.exists ? alert.staticTexts.allElementsBoundByIndex.map(\.label)
            .joined(separator: " | ") : "", file: file, line: line)
        XCTAssertTrue(opened, "The link opens a chat", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch.waitForExistence(timeout: 5), "It's \(name)'s chat", file: file, line: line)
    }
}
