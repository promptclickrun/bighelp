import XCTest

/// Simple Bot mode on demo data: the home (your circle, search, +, the primary
/// bot, the rest), Settings, Create New Bot, search, a bot's menu, its chat and
/// its profile, in light and dark. Set BIGHELP_SIMPLE_BOTS_EVIDENCE
/// (TEST_RUNNER_…) to a folder to save the screenshots.
final class SimpleBotsUITests: BighelpUITestCase {
    @MainActor
    func testSimpleBotModeHomeChatAndProfile() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let home = app.descendants(matching: .any)["simple-bots.home"]
            XCTAssertTrue(home.waitForExistence(timeout: 15), "Simple Bot mode opens on its home")
            XCTAssertFalse(app.buttons["home.drawer.open"].exists, "No ☰ in Simple Bot mode")
            XCTAssertFalse(app.descendants(matching: .any)["tabbar.sessions"].exists, "No tab bar")
            let primary = app.buttons["simple-bots.primary"]
            XCTAssertTrue(primary.exists)
            XCTAssertTrue(app.buttons["simple-bots.bot.travel"].exists, "Other bots are listed")
            save("simple-home-\(appearance)", app)

            // Settings: the short sheet, with the way back to all of bighelp.
            app.buttons["simple-bots.settings"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["simple-bots.settings.mode"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.settings.auto-review"].waitForExistence(timeout: 5),
                          "Auto-review reads the demo host's approvals")
            save("simple-settings-\(appearance)", app)
            app.buttons["simple-bots.settings.close"].tap()

            // Create New Bot.
            app.buttons["simple-bots.new"].tap()
            app.buttons["New Bot"].tap()
            let name = app.textFields["simple-bots.create.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["simple-bots.create.submit"].isEnabled, "Create needs a name")
            app.buttons["simple-bots.shape.hexagon"].tap()
            app.buttons["simple-bots.color.orange"].tap()
            save("simple-create-\(appearance)", app)
            app.buttons["simple-bots.create.close"].tap()

            // Search lists every bot.
            app.buttons["simple-bots.search"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.search.bot.home"].waitForExistence(timeout: 5))
            save("simple-search-\(appearance)", app)
            app.buttons["simple-bots.search.close"].tap()

            // Touch and hold the primary bot.
            primary.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Replace Primary Bot…"].waitForExistence(timeout: 5))
            save("simple-menu-\(appearance)", app)
            app.buttons["Replace Primary Bot…"].tap()
            XCTAssertTrue(app.buttons["simple-bots.primary-pick.travel"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()

            // The primary bot's chat, then its profile from its name.
            primary.tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["chat.new-chat"].exists, "One chat per bot on the home")
            save("simple-chat-\(appearance)", app)
            identity.tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 5))
            app.buttons["simple-bots.shape.star"].tap()
            app.buttons["simple-bots.color.purple"].tap()
            let status = app.staticTexts["simple-bots.profile.mark-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            save("simple-profile-\(appearance)", app)
            app.swipeUp()
            save("simple-profile-lower-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testTurningSimpleBotModeOffComesBackToBighelp() throws {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.settings"].tap()
        let mode = app.switches["simple-bots.settings.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        // The full Settings takes over the sheet; close it.
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 10), "☰ is back")
        XCTAssertFalse(app.descendants(matching: .any)["simple-bots.home"].exists)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIMPLE_BOTS_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
