import XCTest

/// Usage opened from a chat's ⋯ menu and from Settings: it has a top bar with Back, and Back
/// returns to where it was opened from (the chat, or the home Settings was opened over).
/// BIGHELP_USAGE_NAV_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class UsageNavigationUITests: BighelpUITestCase {
    @MainActor
    func testUsageFromTheChatMenuHasBackAndReturnsToTheChat() throws {
        let app = launch()
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 15), "Opens on the agent's chat (-start-chat)")
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
    func testUsageFromSettingsReturnsWhereItWasOpened() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "chats"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["chats.inbox"].firstMatch.waitForExistence(timeout: 15))
        openSettings(in: app)
        // Settings closes and Usage opens over the screen it was opened from.
        settingsRow("simple-bots.settings.usage", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage"].firstMatch.waitForExistence(timeout: 8))
        save("from-settings", app)
        let back = app.navigationBars["Usage"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Usage has its top bar with Back")
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chats.inbox"].firstMatch.waitForExistence(timeout: 5),
                      "Back returns to Chats")
        save("settings-back", app)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
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
