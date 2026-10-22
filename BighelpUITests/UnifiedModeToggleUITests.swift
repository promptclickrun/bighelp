import XCTest

/// Settings › Experience › Unified Mode Toggle: Bots, Chat and Code in a pill at the top of each
/// home, on the demo data, in light and dark. Off out of the box.
/// TEST_RUNNER_BIGHELP_MODE_PILL_EVIDENCE=<folder> saves the screenshots there.
final class UnifiedModeToggleUITests: BighelpUITestCase {
    @MainActor
    func testThePillSwitchesBetweenBotsChatAndCode() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-bighelp.settings.code-mode", "YES"])
            let pill = app.descendants(matching: .any)["mode.pill"]

            // Chat: the list's bar holds the pill, Chat chosen.
            XCTAssertTrue(pill.waitForExistence(timeout: 15), "The pill shows on the Chat tab")
            XCTAssertTrue(app.buttons["mode.pill.chat"].isSelected)
            XCTAssertTrue(app.buttons["mode.pill.code"].exists, "Code is offered while Code mode is on")
            save("chat-\(appearance)", app)

            // Code: its home, with the same pill in its bar.
            app.buttons["mode.pill.code"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["code.screen"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["mode.pill.code"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["mode.pill.code"].isSelected)
            save("code-\(appearance)", app)

            // Bots: its calm home; Search moves under the pill.
            app.buttons["mode.pill.bots"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["mode.pill.bots"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["mode.pill.bots"].isSelected)
            let search = app.buttons["simple-bots.search"]
            XCTAssertTrue(search.exists)
            XCTAssertGreaterThan(search.frame.minY, app.buttons["mode.pill.bots"].frame.maxY,
                                 "Search sits on the row under the pill")
            save("bots-\(appearance)", app)

            // And back to Chat.
            app.buttons["mode.pill.chat"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.buttons["mode.pill.chat"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["mode.pill.chat"].isSelected)
            app.terminate()
        }
    }

    @MainActor
    func testTheAgentsOwnChatCarriesThePill() throws {
        let app = launch(appearance: "light", extra: ["-loopdy.home.opens-chat", "YES"])
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 15), "The Chat tab opens the agent's chat")
        XCTAssertTrue(app.buttons["mode.pill.chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["mode.pill.code"].exists, "Code waits for Settings › Code mode")
        XCTAssertGreaterThan(chatIdentity(in: app).frame.minY, app.buttons["mode.pill.chat"].frame.maxY,
                             "The agent steps down below the pill")
        save("home-chat-light", app)
    }

    @MainActor
    func testThePillIsOffOutOfTheBox() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["mode.pill"].exists)
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.unified-mode-toggle", "YES",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MODE_PILL_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
