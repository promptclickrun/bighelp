import XCTest

/// The iPhone Duo. The cover-screen tests run on the Duo's simulator, which starts folded: the bar in
/// the side column and the switcher beside a chat. A test can't open
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
            let today = app.buttons["home.tab.today"].firstMatch
            XCTAssertTrue(today.waitForExistence(timeout: 20), "The places show")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(today.frame.minX, window.maxX - 90, "In the side strip")
            XCTAssertGreaterThan(today.frame.minY, window.minY + 150, "Under the camera and the status")
            let chat = app.buttons["home.tab.conversations"].firstMatch
            XCTAssertLessThan(abs(chat.frame.midX - today.frame.midX), 4, "One above the other")
            save("cover-chat-\(appearance)", app)
            if appearance == "light" {
                today.tap()
                // iOS doesn't report a toolbar button as selected: the Today page is what shows.
                XCTAssertTrue(element("today.home", in: app).waitForExistence(timeout: 5),
                              "The places in the strip work")
                save("cover-today-light", app)
            }
            app.terminate()
        }
    }

    @MainActor
    func testCoverScreenSwitchesBotsFromBesideTheChat() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-loopdy.home.landing", "bots", "-test-bot-activity",
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
    func testIPadBotSwitcherStaysBelowStatusBar() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-loopdy.home.landing", "bots", "-test-bot-activity",
                                          "-bighelp.settings.chat-switcher", "YES",
                                          "-loopdy.demo.appearance", appearance]
            app.launch()
            try requireWideScreen(app)
            let mina = app.buttons["simple-bots.bot.travel"]
            XCTAssertTrue(mina.waitForExistence(timeout: 20))
            mina.tap()
            let switcher = element("chat-switcher", in: app)
            XCTAssertTrue(switcher.waitForExistence(timeout: 10))
            // The header's Back button follows the window's safe area; the status bar itself
            // is not exposed in the app's accessibility tree on every iPad runtime.
            let back = app.buttons["chat.back"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(switcher.frame.minY, back.frame.minY,
                                       "The whole glass rail stays below the safe-area header's top")
            save("ipad-bots-switcher-\(appearance)", app)
            let jordan = app.buttons.matching(identifier: "chat-switcher.stop")
                .matching(NSPredicate(format: "label == %@", "Jordan Lee")).firstMatch
            jordan.tap()
            XCTAssertTrue(jordan.waitForSelection(timeout: 10))
            app.terminate()
        }
    }

    // MARK: Open and half-folded (an iPad simulator standing in)

    @MainActor
    func testOpenScreenShowsTheListBesideTheChatInBothViews() throws {
        let modes: [(name: String, arguments: [String], list: String)] = [
            ("bots", ["-loopdy.home.landing", "bots", "-test-bot-activity"], "simple-bots.home"),
            ("chat", ["-loopdy.home.landing", "chats"], "chats.inbox"),
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
            XCTAssertTrue(field.waitForExistence(timeout: 20), "The chat opens")
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
