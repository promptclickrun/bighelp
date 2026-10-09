import XCTest

/// Usage opened from a chat's ⋯ menu and from ☰, the way people open the app (on the agent's
/// chat): it has a top bar with Back, and Back returns to where it was opened from.
/// BIGHELP_USAGE_NAV_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class UsageNavigationUITests: BighelpUITestCase {
    @MainActor
    func testUsageFromTheChatMenuHasBackAndReturnsToTheChat() throws {
        let app = launch()
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 15), "Opens on the agent's chat")
        let usage = chatMenuItem("chat.provider-usage", in: app)
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage"].firstMatch.waitForExistence(timeout: 8))
        save("from-chat", app)
        let back = app.navigationBars["Usage"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Usage has its top bar with Back")
        back.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5), "Back returns to the chat")
        save("back-to-chat", app)
    }

    @MainActor
    func testUsageFromTheMenuReturnsWhereItWasOpened() throws {
        let app = launch()
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let usage = app.buttons["menu.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage"].firstMatch.waitForExistence(timeout: 8))
        save("from-menu", app)
        let back = app.navigationBars["Usage"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Usage has its top bar with Back")
        back.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5), "Back returns to the chat")
        save("menu-back", app)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES"]
        app.launch()
        return app
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_USAGE_NAV_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
