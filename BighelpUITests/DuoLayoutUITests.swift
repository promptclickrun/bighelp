import XCTest

/// The iPhone Duo. The cover-screen tests run on the Duo's simulator, which starts folded: the bar in
/// the side column, and beside a chat the switcher with work in another chat above it. A test can't open
/// or fold that simulator, so the open screen and the half-folded laptop run on an iPad simulator with
/// `-bighelp.debug.screen-posture` and `-bighelp.debug.fold-halfway`. Each test skips on a screen it
/// isn't for. Set BIGHELP_DUO_EVIDENCE (TEST_RUNNER_…) to a folder to save the screenshots.
final class DuoLayoutUITests: BighelpUITestCase {
    private let demo = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
    /// How far down its column the Duo's camera and status reach: the app's
    /// `BighelpScreenGeometry.statusAreaHeight`. A UI test can't read the app's constant, so
    /// `testCoverScreenChatColumnStaysUnderTheStatusWithNoReportOfItsEnd` checks it against what the
    /// system reports.
    private static let statusAreaHeight: CGFloat = 174
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
            XCTAssertGreaterThanOrEqual(today.frame.minY, window.minY + Self.statusAreaHeight,
                                        "Under the camera and the status")
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

    /// The Duo has no island, so a chat's column says who works in another chat: a face and a
    /// line under the camera, above the chats' faces. A tap opens the chat where the work is.
    @MainActor
    func testCoverScreenColumnShowsWorkInAnotherChat() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-start-chat", "-test-tool-stream", "-test-tool-stream-hold", "90",
                                          "-loopdy.demo.appearance", appearance]
            app.launch()
            try requireCoverScreen(app)
            // Avery starts work in his chat: a turn that really runs.
            let sent = send("Check the March budget", in: app)
            // Mina's chat, from the switcher beside it.
            let mina = app.buttons.matching(identifier: "chat-switcher.stop")
                .matching(NSPredicate(format: "label == %@", "Mina Shah")).firstMatch
            XCTAssertTrue(mina.waitForExistence(timeout: 10), "The switcher is beside the chat")
            mina.tap()
            let identity = app.buttons["chat.identity"].firstMatch
            XCTAssertTrue(waitForLabel("Mina Shah", of: identity), "Mina's chat is the open one")

            let pill = app.buttons["chat.working-elsewhere"].firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 10), "The column says Avery works in another chat")
            XCTAssertTrue(pill.label.hasPrefix("Avery Park, "), "Who, then what: \(pill.label)")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(pill.frame.minX, window.maxX - 90, "In the side column")
            XCTAssertGreaterThanOrEqual(pill.frame.minY, window.minY + Self.statusAreaHeight,
                                        "Under the camera and the status")
            let switcher = element("chat-switcher", in: app)
            XCTAssertTrue(switcher.exists, "The chats' faces stay")
            XCTAssertLessThanOrEqual(pill.frame.maxY, switcher.frame.minY, "Above the chats' faces")
            XCTAssertLessThan(abs(pill.frame.midX - switcher.frame.midX), 4, "In one column with them")
            sleep(1)
            save("cover-working-elsewhere-\(appearance)", app)

            pill.tap()
            XCTAssertTrue(sent.waitForExistence(timeout: 10), "A tap opens the chat where Avery works")
            XCTAssertTrue(waitForLabel("Avery Park", of: identity))
            // That chat says its own work: nothing is left for its column to say.
            XCTAssertTrue(pill.waitForNonExistence(timeout: 5), "The working chat's own column is quiet")
            app.terminate()
        }
    }

    /// Nothing is drawn while no other chat works: not at rest, and not for the open chat's own work.
    @MainActor
    func testCoverScreenColumnIsQuietWhileNoOtherChatWorks() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-start-chat", "-test-tool-stream", "-test-tool-stream-hold", "20",
                                          "-loopdy.demo.appearance", appearance]
            app.launch()
            try requireCoverScreen(app)
            XCTAssertTrue(app.textViews["Message"].waitForExistence(timeout: 20), "The chat opens")
            let pill = app.buttons["chat.working-elsewhere"].firstMatch
            XCTAssertTrue(element("chat-switcher", in: app).waitForExistence(timeout: 10))
            XCTAssertFalse(pill.exists, "Every bot rests: the column holds only the chats' faces")
            save("cover-idle-\(appearance)", app)
            _ = send("Check the March budget", in: app)
            sleep(2)
            XCTAssertFalse(pill.exists, "The open chat's own work stays out of its column")
            app.terminate()
        }
    }

    /// The system says where the camera and the status end in its column, and its API may say
    /// nothing. A chat's column (work in another chat, then the chats' faces) must then start where
    /// it starts with the report, never under the status.
    @MainActor
    func testCoverScreenChatColumnStaysUnderTheStatusWithNoReportOfItsEnd() throws {
        let reported = try chatColumn(appearance: "light", withholdsStatusArea: false, saveAs: nil)
        print("DUO-COLUMN reported pill=\(reported.pill) switcher=\(reported.switcher)")
        // The column starts 8 points under the area the system reports: the height the app keeps
        // clear without a report is that area's.
        XCTAssertEqual(reported.pill.minY, Self.statusAreaHeight + 8, accuracy: 1,
                       "The system reports a status area as tall as the app takes it to be")
        var withheld: [(appearance: String, pill: CGRect, switcher: CGRect)] = []
        // Both pictures first, so a failure still leaves light and dark to look at.
        for appearance in appearances {
            let column = try chatColumn(appearance: appearance, withholdsStatusArea: true,
                                        saveAs: "cover-chat-column-no-status-report-\(appearance)")
            print("DUO-COLUMN withheld \(appearance) pill=\(column.pill) switcher=\(column.switcher)")
            withheld.append((appearance, column.pill, column.switcher))
        }
        for column in withheld {
            XCTAssertEqual(column.pill.minY, reported.pill.minY, accuracy: 1,
                           "\(column.appearance): the pill starts under the status, as with the report")
            XCTAssertEqual(column.switcher.minY, reported.switcher.minY, accuracy: 1,
                           "\(column.appearance): the chats' faces start where they do with the report")
            XCTAssertEqual(column.pill.midX, reported.pill.midX, accuracy: 1, "\(column.appearance): in the same column")
        }
    }

    /// A chat's side column with work in another chat: Avery starts a turn that really runs, then
    /// Mina's chat opens from the list, so getting there never depends on the column under test.
    /// Returns where the pill and the chats' faces are.
    @MainActor
    private func chatColumn(appearance: String, withholdsStatusArea: Bool,
                            saveAs name: String?) throws -> (pill: CGRect, switcher: CGRect) {
        let app = makeApp()
        app.launchArguments = demo + ["-start-chat", "-test-tool-stream", "-test-tool-stream-hold", "90",
                                      "-loopdy.demo.appearance", appearance]
            + (withholdsStatusArea ? ["-bighelp.debug.no-occlusion", "YES"] : [])
        app.launch()
        defer { app.terminate() }
        try requireCoverScreen(app)
        _ = send("Check the March budget", in: app)
        app.buttons["chat.back"].firstMatch.tap()
        let mina = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "demo-travel")).firstMatch
        XCTAssertTrue(mina.waitForExistence(timeout: 10), "The list has Mina's chat")
        mina.tap()
        XCTAssertTrue(waitForLabel("Mina Shah", of: app.buttons["chat.identity"].firstMatch), "Mina's chat opens")
        let pill = app.buttons["chat.working-elsewhere"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "The column says Avery works in another chat")
        let switcher = element("chat-switcher", in: app)
        XCTAssertTrue(switcher.exists, "The chats' faces are under it")
        sleep(1)
        if let name { save(name, app) }
        return (pill.frame, switcher.frame)
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

    // MARK: The cover screen's own affordances

    @MainActor
    func testCoverScreenOpensPhotosOverTheWholeDisplay() throws {
        for appearance in appearances {
            let app = makeApp()
            app.launchArguments = demo + ["-start-chat", "-test-image-stack", "-loopdy.demo.appearance", appearance]
            app.launch()
            try requireCoverScreen(app)
            let agentStack = app.descendants(matching: .any).matching(identifier: "chat.image-stack")
                .matching(NSPredicate(format: "label == %@", "4 photos")).firstMatch
            XCTAssertTrue(agentStack.waitForExistence(timeout: 20), "The agent's four photos show as a stack")
            agentStack.tap()
            let pages = element("chat.image-stack.pages", in: app)
            XCTAssertTrue(pages.waitForExistence(timeout: 10), "The photos open")
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(pages.frame.width, window.width - 40,
                                "The picture takes the display instead of a sheet inset for the bar")
            XCTAssertFalse(app.navigationBars["1 of 4"].exists,
                           "No bar stands a column up over the picture")
            let position = element("chat.image-stack.position", in: app)
            XCTAssertTrue(position.waitForExistence(timeout: 5), "The pictures say which is showing")
            XCTAssertEqual(position.label, "1 of 4")
            let close = element("chat.image-stack.close", in: app)
            XCTAssertTrue(close.exists, "A way out, where the bar would have been")
            XCTAssertLessThan(close.frame.midX, window.midX, "Down the leading edge, clear of the column")
            sleep(1)
            save("cover-photos-\(appearance)", app)
            if appearance == "light" {
                app.buttons["chat.image-stack.thumbnail.2"].tap()
                XCTAssertEqual(element("chat.image-stack.position", in: app).label, "3 of 4",
                               "The thumbnails jump to a picture")
                app.buttons["chat.image-stack.save"].tap()
                XCTAssertTrue(app.buttons["Save All 4 Photos"].waitForExistence(timeout: 5),
                              "Save still offers all of them")
                XCTAssertTrue(app.buttons["Save This Photo"].exists)
                save("cover-photos-save-light", app)
                pages.tap()
                close.tap()
                XCTAssertTrue(pages.waitForNonExistence(timeout: 5), "Close leaves the photos")
            }
            app.terminate()
        }
    }

    @MainActor
    func testCoverScreenKeepsTheAgentsFaceWhereItsMenuWas() throws {
        let app = makeApp()
        app.launchArguments = demo + ["-loopdy.demo.appearance", "light"]
        app.launch()
        try requireCoverScreen(app)
        let feed = app.buttons["tab.feed"].firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 20), "The places are in the side strip")
        feed.tap()
        let face = app.buttons["board.more"].firstMatch
        XCTAssertTrue(face.waitForExistence(timeout: 10), "The agent's face is where the menu was")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(face.frame.midX, window.midX, "It sits with the screen's other buttons")
        XCTAssertLessThan(face.frame.maxX, window.maxX - 60,
                          "Clear of the camera and the status, which have the column beside it")
        sleep(1)
        save("cover-board-face-light", app)
        face.tap()
        XCTAssertTrue(app.buttons["Agent profile"].waitForExistence(timeout: 5),
                      "The face opens the same menu")
        save("cover-board-face-menu-light", app)
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
            // The half under the fold is a desk: the bot and what it's doing, then New chat and Bot
            // page, under the message box.
            XCTAssertTrue(element("chat.laptop.desk", in: app).waitForExistence(timeout: 5),
                          "The half under the fold carries the desk")
            XCTAssertEqual(element("chat.laptop.status", in: app).label, "Avery Park, Here for you",
                           "It says who the bot is and what it's doing, once")
            for id in ["chat.laptop.new-chat", "chat.laptop.bot-page"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.waitForExistence(timeout: 5), "\(id) is in reach under the fold")
                XCTAssertGreaterThan(button.frame.minY, field.frame.maxY, "\(id) sits under the message box")
                XCTAssertLessThan(button.frame.maxY, window.maxY, "\(id) is on screen")
            }
            sleep(1)
            save("laptop-chat-\(appearance)", app)
            if appearance == "light" {
                field.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                XCTAssertGreaterThan(field.frame.minY, window.midY, "Typing, it rests on the keyboard, still under the fold")
                XCTAssertFalse(element("chat.laptop.desk", in: app).exists, "Typing, the desk gets out of the way")
                save("laptop-typing-light", app)
            } else {
                app.buttons["chat.laptop.bot-page"].tap()
                XCTAssertTrue(app.buttons["simple-bots.profile.more"].waitForExistence(timeout: 10),
                              "Bot page opens the bot's page")
            }
            app.terminate()
        }
    }

    // MARK: Every screen

    /// From iOS 27 a project's actions sit in the system's overflow menu, so its bar has one "⋯" and
    /// the Duo's column doesn't stack ours above the system's. Runs on any simulator.
    @MainActor
    func testAProjectsActionsSitInTheSystemsOverflowMenu() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("The system's overflow menu came with iOS 27") }
        let app = makeApp()
        app.launchArguments = demo + ["-loopdy.demo.appearance", "light"]
        app.launch()
        openRootTab("tab.projects", in: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The demo has a project")
        card.tap()
        XCTAssertTrue(element("project.screen", in: app).waitForExistence(timeout: 10), "The project opens")
        XCTAssertFalse(app.buttons["project.options"].exists, "No menu of our own beside the system's")
        sleep(1)
        save("project-bar-light", app)
        let overflow = app.buttons.matching(
            NSPredicate(format: "label == %@ OR identifier CONTAINS[c] %@", "More", "overflow")).firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 5), "The system's overflow is on the screen:\n\(app.debugDescription)")
        overflow.tap()
        XCTAssertTrue(app.buttons["Archive project"].waitForExistence(timeout: 5), "It holds the project's actions")
        save("project-overflow-light", app)
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

    /// Sends a message in the open chat and returns its row. With `-test-tool-stream` the bot then
    /// works for as long as `-test-tool-stream-hold` says.
    @MainActor
    private func send(_ text: String, in app: XCUIApplication) -> XCUIElement {
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "The chat opens")
        input.tap()
        input.typeText(text)
        app.buttons["chat.send"].tap()
        let sent = app.textViews["You: \(text)"]
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "The message is in the chat")
        return sent
    }

    /// Waits for a label (a chat's header naming its bot).
    @MainActor
    private func waitForLabel(_ label: String, of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, element.label == label { return true }
            usleep(200_000)
        }
        return false
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
