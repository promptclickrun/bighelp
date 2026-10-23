import XCTest

/// The iPhone Duo. The cover-screen tests run on the Duo's simulator, which starts folded: the bar in
/// the side column (Chat mode) and the switcher beside a chat (Bots and Code mode). A test can't open
/// or fold that simulator, so the open screen and the half-folded laptop run on an iPad simulator with
/// `-bighelp.debug.screen-posture` and `-bighelp.debug.fold-halfway`. Each test skips on a screen it
/// isn't for. Set BIGHELP_DUO_EVIDENCE (TEST_RUNNER_…) to a folder to save the screenshots.
final class DuoLayoutUITests: BighelpUITestCase {
    private let demo = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
    private let appearances = ["light", "dark"]

    // MARK: Cover screen (the Duo's simulator)

    @MainActor
    func testCoverScreenStandsTheBarUpInTheSideColumn() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-loopdy.demo.appearance", appearance]
            app.launch()
            try requireCoverScreen(app)
            // The bar's places are toolbar items, which iOS stacks down the side strip.
            let feed = app.buttons["tab.feed"].firstMatch
            XCTAssertTrue(feed.waitForExistence(timeout: 20), "The places show")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(feed.frame.minX, window.maxX - 90, "In the side strip")
            XCTAssertGreaterThan(feed.frame.minY, window.minY + 150, "Under the camera and the status")
            let chat = app.buttons["tab.sessions"].firstMatch
            XCTAssertLessThan(abs(chat.frame.midX - feed.frame.midX), 4, "One above the other")
            let menu = app.buttons["home.drawer.open"].firstMatch
            if menu.exists {
                XCTAssertFalse(menu.frame.intersects(feed.frame) || menu.frame.intersects(chat.frame),
                               "Nothing lies over the screen's own buttons")
            }
            save("cover-chat-\(appearance)", app)
            if appearance == "light" {
                feed.tap()
                // iOS doesn't report a toolbar button as selected: the Feed page is what shows.
                XCTAssertTrue(element("chat.composer.field", in: app).waitForNonExistence(timeout: 5),
                              "The places in the strip work")
                save("cover-feed-light", app)
            }
            app.terminate()
        }
    }

    @MainActor
    func testCoverScreenSwitchesBotsFromBesideTheChat() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-bighelp.settings.simple-bots", "YES", "-test-bot-activity",
                                          "-loopdy.demo.appearance", appearance]
            app.launch()
            try requireCoverScreen(app)
            let mina = app.buttons["simple-bots.bot.travel"]
            XCTAssertTrue(mina.waitForExistence(timeout: 20))
            mina.tap()
            let switcher = element("chat-switcher", in: app)
            XCTAssertTrue(switcher.waitForExistence(timeout: 10), "A bot's chat has the switcher beside it")
            let stops = app.buttons.matching(identifier: "chat-switcher.stop")
            XCTAssertGreaterThanOrEqual(stops.count, 3, "The primary bot and the others")
            let current = stops.matching(NSPredicate(format: "label == %@", "Mina Shah")).firstMatch
            XCTAssertTrue(current.isSelected, "Mina's chat is the open one")
            XCTAssertGreaterThan(switcher.frame.minX, app.windows.firstMatch.frame.maxX - 90, "In the side column")
            sleep(1)
            save("cover-bots-switcher-\(appearance)", app)
            if appearance == "light" {
                let jordan = stops.matching(NSPredicate(format: "label == %@", "Jordan Lee")).firstMatch
                jordan.tap()
                XCTAssertTrue(jordan.waitForSelection(timeout: 10), "A tap opens Jordan's chat")
                XCTAssertTrue(app.buttons["chat.back"].exists, "Back still goes home")
            }
            app.terminate()
        }
    }

    @MainActor
    func testCoverScreenSwitchesCodeSessionsFromBesideTheChat() throws {
        let app = makeApp()
        app.launchArguments = demo + ["-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code",
                                      "-loopdy.demo.appearance", "light"]
        app.launch()
        try requireCoverScreen(app)
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 15))
        for message in ["Fix the widget tap when the host is asleep", "Tighten the Usage chart spacing"] {
            let field = element("code.composer.field", in: app)
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(message)
            app.buttons["code.composer.send"].tap()
        }
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "code.session."))
        let deadline = Date().addingTimeInterval(10)
        while cards.count < 2, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(cards.count, 2)
        cards.firstMatch.tap()
        let switcher = element("chat-switcher", in: app)
        XCTAssertTrue(switcher.waitForExistence(timeout: 10), "A session's chat has the switcher beside it")
        let stops = app.buttons.matching(identifier: "chat-switcher.stop")
        XCTAssertEqual(stops.count, 2, "One tile for each session")
        sleep(1)
        save("cover-code-switcher-light", app)
        // Switching goes in place of the open chat (it never piles chats up for Back to walk
        // through; the shell drops the open chat first), and the tapped session becomes the one open.
        for _ in 0..<2 {
            let label = stops.matching(NSPredicate(format: "selected == NO")).firstMatch.label
            stops.matching(NSPredicate(format: "label == %@", label)).firstMatch.tap()
            XCTAssertTrue(stops.matching(NSPredicate(format: "label == %@", label)).firstMatch.waitForSelection(timeout: 10))
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat-switcher").count, 1)
    }

    // MARK: Open and half-folded (an iPad simulator standing in)

    @MainActor
    func testOpenScreenShowsTheListBesideTheChatInEveryMode() throws {
        let modes: [(name: String, arguments: [String], list: String)] = [
            ("bots", ["-bighelp.settings.simple-bots", "YES", "-test-bot-activity"], "simple-bots.home"),
            ("chat", [], "sessions.screen"),
            ("code", ["-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code"], "code.screen"),
        ]
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for mode in modes {
            for appearance in appearances {
                let app = makeApp()
                app.launchArguments = demo + mode.arguments + ["-loopdy.demo.appearance", appearance,
                                                               "-bighelp.debug.screen-posture", "open",
                                                               "-bighelp.debug.fold-halfway", "YES"]
                app.launch()
                try requireWideScreen(app)
                let list = element(mode.list, in: app)
                XCTAssertTrue(list.waitForExistence(timeout: 20), "\(mode.name): the list shows")
                let window = app.windows.firstMatch.frame
                XCTAssertLessThan(list.frame.maxX, window.midX + 2, "\(mode.name): the list stops at the fold")
                if mode.name == "bots" {
                    app.buttons["simple-bots.bot.travel"].tap()
                    XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10))
                    XCTAssertTrue(list.exists, "Bots: the list stays beside the chat")
                } else if mode.name == "chat" {
                    XCTAssertTrue(element("split.placeholder", in: app).exists || app.buttons["chat.back"].exists)
                }
                sleep(1)
                save("open-\(mode.name)-\(appearance)", app)
                app.terminate()
            }
        }
    }

    @MainActor
    func testHalfFoldedLikeALaptopKeepsTheMessagesAboveTheFold() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-start-chat", "-loopdy.demo.appearance", appearance,
                                          "-bighelp.debug.screen-posture", "openUpright",
                                          "-bighelp.debug.fold-halfway", "YES"]
            app.launch()
            try requireWideScreen(app)
            let field = element("chat.composer.field", in: app)
            XCTAssertTrue(field.waitForExistence(timeout: 20), "The home chat opens")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(field.frame.minY, window.midY, "The message box sits under the fold")
            XCTAssertLessThan(field.frame.minY, window.midY + 120, "Just under it")
            sleep(1)
            save("laptop-chat-\(appearance)", app)
            if appearance == "light" {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(field.frame.minY, window.midY, "Typing, it rests on the keyboard, still under the fold")
                save("laptop-typing-light", app)
            }
            app.terminate()
        }
    }

    // MARK: Helpers

    @MainActor
    private func requireCoverScreen(_ app: XCUIApplication) throws {
        let frame = app.windows.firstMatch.frame
        try XCTSkipUnless(frame.width < 520 && frame.height / max(frame.width, 1) < 1.7,
                          "Runs on the iPhone Duo's simulator, folded")
    }

    @MainActor
    private func requireWideScreen(_ app: XCUIApplication) throws {
        let frame = app.windows.firstMatch.frame
        try XCTSkipUnless(min(frame.width, frame.height) > 600, "Runs on an iPad simulator standing in for the open Duo")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_DUO_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // The screen's, not the app's: an iPad on its side crops the app's.
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

private extension XCUIElement {
    /// Waits for the selected trait (a tab or a switcher stop becoming the current one).
    func waitForSelection(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isSelected { return true }
            usleep(200_000)
        }
        return false
    }
}
