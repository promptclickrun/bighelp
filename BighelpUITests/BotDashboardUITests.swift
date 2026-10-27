import XCTest

/// A bot's profile opens on its Dashboard: Feed, Ideas and Goals as piles. Swiping the top Feed
/// card left clears it, with Undo.
final class BotDashboardUITests: BighelpUITestCase {
    @MainActor
    func testProfileOpensOnTheDashboardAndASwipeClearsAPost() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", "light"]
        app.launch()
        let primary = app.buttons["simple-bots.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 15))
        primary.tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        // A tap while the chat is still sliding in can miss; one more is enough.
        identity.tap()
        if !profile.waitForExistence(timeout: 5) { identity.tap() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5))

        XCTAssertTrue(app.descendants(matching: .any)["dashboard"].waitForExistence(timeout: 5), "Dashboard comes first")
        XCTAssertTrue(app.buttons["simple-bots.profile.tab.dashboard"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.idea"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.goal"].exists)

        // The demo's newest post is on top of the Feed pile.
        let top = app.descendants(matching: .any)["dashboard.card.feed-1"]
        XCTAssertTrue(top.waitForExistence(timeout: 10))
        top.swipeLeft(velocity: .fast)
        XCTAssertTrue(app.buttons["dashboard.undo"].waitForExistence(timeout: 5), "Undo shows after the swipe")
        XCTAssertFalse(top.exists, "The post left the pile")
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.card.feed-2"].exists, "The next one is on top")

        app.buttons["dashboard.undo"].tap()
        XCTAssertTrue(top.waitForExistence(timeout: 5), "Undo brings it back")

        // Right: the bot's own chat (history and all) with the post in its message box, not sent.
        top.swipeRight(velocity: .fast)
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The bot's chat opens")
        let draft = NSPredicate(format: "value BEGINSWITH %@", "About “Lisbon fares dropped 18% for October”")
        expectation(for: draft, evaluatedWith: composer)
        waitForExpectations(timeout: 5)
    }

    /// Screenshots for design review, only when `BIGHELP_DASHBOARD_SHOTS` names a folder: the
    /// Dashboard in light and dark, the tutorial, the Templates deck and a brand-new bot. A file
    /// `drag-start` there tells a watcher outside the test when a card is held mid-swipe.
    @MainActor
    func testDashboardScreenshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_DASHBOARD_SHOTS"] else {
            throw XCTSkip("Set BIGHELP_DASHBOARD_SHOTS to a folder to take the screenshots")
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        func shot(_ name: String, _ app: XCUIApplication) {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance,
                                   "-bighelp.dashboard.swipe-tutorial-seen", "NO"]
            app.launch()
            openProfile(app, bot: "simple-bots.primary")
            do {
                let skip = app.buttons["dashboard.tutorial.skip"]
                XCTAssertTrue(skip.waitForExistence(timeout: 10), "The tutorial shows the first time there are cards")
                Thread.sleep(forTimeInterval: 0.6)
                shot("tutorial-\(appearance)", app)
                let practice = app.descendants(matching: .any)["dashboard.tutorial.card"]
                practice.swipeLeft(velocity: .fast)
                Thread.sleep(forTimeInterval: 0.8)
                shot("tutorial-step2-\(appearance)", app)
                practice.swipeRight(velocity: .fast)
                XCTAssertTrue(app.buttons["dashboard.tutorial.done"].waitForExistence(timeout: 5))
                shot("tutorial-done-\(appearance)", app)
                app.buttons["dashboard.tutorial.done"].tap()
            }
            Thread.sleep(forTimeInterval: 0.8)
            shot("dashboard-\(appearance)", app)
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            shot("dashboard-lower-\(appearance)", app)
            app.swipeDown()

            if appearance == "light" {
                let card = app.descendants(matching: .any)["dashboard.card.feed-1"]
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                FileManager.default.createFile(atPath: folder + "/drag-start", contents: nil)
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 85, dy: 4)),
                            withVelocity: .slow, thenHoldForDuration: 3)
                try? FileManager.default.removeItem(atPath: folder + "/drag-start")
                Thread.sleep(forTimeInterval: 0.8)
            }

            app.buttons["dashboard.templates"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["dashboard.templates.sheet"].waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.8)
            shot("templates-\(appearance)", app)
            app.buttons["dashboard.templates.page.goal"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            shot("templates-goals-\(appearance)", app)
            app.buttons["dashboard.templates.done"].tap()
            app.terminate()

            // The demo's brand-new bot: every pile empty.
            app.launch()
            openProfile(app, bot: "simple-bots.bot.home")
            XCTAssertTrue(app.descendants(matching: .any)["dashboard.feed.empty"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 0.6)
            shot("empty-bot-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func openProfile(_ app: XCUIApplication, bot: String) {
        let button = app.buttons[bot]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        identity.tap()
        if !profile.waitForExistence(timeout: 5) { identity.tap() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
    }
}
