import XCTest

/// An agent showing the person a place (#662), on demo data: `-test-agent-drive` plays one drive in
/// the first chat that opens, through the real navigator, routes and overlay. Set
/// BIGHELP_DRIVE_EVIDENCE (TEST_RUNNER_…) to a folder to save the screenshots.
final class AgentDriveUITests: BighelpUITestCase {
    @MainActor
    func testFeedTemplatesDriveOpensTheDeckAndReturnsToTheChat() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", "light",
                               "-test-agent-drive", "bot.dashboard.templates.feed",
                               "-test-agent-drive-note", "Each card is something your Feed can do. Swipe right to use one."]
        app.launch()
        let primary = app.buttons["simple-bots.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 15))
        primary.tap()
        XCTAssertTrue(app.buttons["chat.identity"].waitForExistence(timeout: 5))

        let bar = app.descendants(matching: .any)["drive.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "The bar grows out of the island")
        XCTAssertTrue(app.descendants(matching: .any)["drive.dock"].exists, "The chat waits in the dock")
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.templates.sheet"].waitForExistence(timeout: 12),
                      "The drive went to the bot's profile, its Dashboard and the Templates deck")
        XCTAssertTrue(app.descendants(matching: .any)["drive.note"].waitForExistence(timeout: 6),
                      "It ends on a spotlight with the agent's note")
        save("arrived", app)

        // The bar lives in its own window, which XCUITest can't compute a hit point for; tap where a
        // finger would, so the touch goes through the overlay window's own hit test.
        let back = app.buttons["drive.return"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: back.midX, dy: back.midY)).tap()
        XCTAssertTrue(app.buttons["chat.identity"].waitForExistence(timeout: 5), "Return to chat goes back to the chat")
        XCTAssertFalse(app.descendants(matching: .any)["dashboard.templates.sheet"].exists)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)
        waitForExpectations(timeout: 4)
        save("returned", app)
    }

    @MainActor
    func testSettingsDrivePointsAtReturnSendsAndClosesSettingsOnReturn() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                               "-loopdy.demo.appearance", "dark",
                               "-test-agent-drive", "settings.chat.return-sends",
                               "-test-agent-drive-note", "Turn this on and Return sends your message."]
        app.launch()
        let bar = app.descendants(matching: .any)["drive.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "The bar grows out of the island")
        XCTAssertTrue(app.descendants(matching: .any)["settings.chat.return-sends"].waitForExistence(timeout: 12),
                      "The drive opened Settings › Chat")
        XCTAssertTrue(app.descendants(matching: .any)["drive.note"].waitForExistence(timeout: 6))
        save("settings-arrived", app)

        let back = app.buttons["drive.return"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: back.midX, dy: back.midY)).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)
        waitForExpectations(timeout: 4)
        XCTAssertFalse(app.descendants(matching: .any)["settings.chat.return-sends"].exists, "Settings closed again")
        save("settings-returned", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_DRIVE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
