import XCTest

/// Settings › Chat › A bot opens decides what tapping an agent on Agents opens,
/// and an agent's Bot Chat offers This chat › New Bot Chat. On the demo data, whose
/// finance agent has a Bot Chat. Set BIGHELP_BOT_CHAT_EVIDENCE (TEST_RUNNER_…) to save
/// screenshots.
final class BotChatUITests: BighelpUITestCase {
    private let botChatText = "This is the shared Bot Chat."

    @MainActor
    func testBotChatExperienceDecidesWhatAnAgentTapOpens() {
        for (experience, opensBotChat) in [(nil, true), ("lastChat", false), ("newChat", false)] as [(String?, Bool)] {
            let app = launch(experience)
            tapAgent("finance", in: app)
            XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 15))
            let botChat = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", botChatText)).firstMatch
            XCTAssertEqual(botChat.waitForExistence(timeout: opensBotChat ? 10 : 3), opensBotChat,
                           "\(experience ?? "default") opens the Bot Chat: \(opensBotChat)")
            app.terminate()
        }
    }

    @MainActor
    func testTheBotChatOffersANewOneAndTheSettingShows() {
        for appearance in ["light", "dark"] {
            let app = launch(nil, appearance: appearance)
            tapAgent("finance", in: app)
            let botChat = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", botChatText)).firstMatch
            XCTAssertTrue(botChat.waitForExistence(timeout: 15))
            _ = chatMenuItem("chat.rename", in: app)
            // Native menu rows can expose their title instead of their identifier.
            let newBotChat = app.buttons.matching(NSPredicate(
                format: "identifier == %@ OR label == %@", "chat.new-bot-chat", "New Bot Chat")).firstMatch
            XCTAssertTrue(newBotChat.waitForExistence(timeout: 5), "⋯ › New Bot Chat in a Bot Chat")
            save("this-chat-\(appearance)", app)
            app.terminate()

            let settings = launch(nil, appearance: appearance)
            openSettings(in: settings)
            settingsRow("settings.menu.chat", in: settings).tap()
            let picker = settings.descendants(matching: .any)["settings.chat.bot-chat-experience"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.staticTexts["Its ongoing chat"].exists, "Its ongoing chat is the default")
            save("settings-\(appearance)", settings)
            settings.terminate()
        }
    }

    /// ⋯ › Usage › Compact shows a chip above the message box, then Done with what it saved.
    @MainActor
    func testCompactShowsTheRailThenFinishes() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 15))
            let compact = chatCompactItem(in: app)
            XCTAssertTrue(compact.waitForExistence(timeout: 5), "Usage has Compact")
            save("compact-menu-\(appearance)", app)
            compact.tap()
            let running = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ AND label CONTAINS %@", "chat.compaction.running", "Compacting 48 messages")).firstMatch
            XCTAssertTrue(running.waitForExistence(timeout: 15), "Compacting shows above the message box")
            save("compaction-running-\(appearance)", app)
            let done = app.descendants(matching: .any)["chat.compaction.done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 12), "Then Done")
            save("compaction-done-\(appearance)", app)
            XCTAssertTrue(done.waitForNonExistence(timeout: 6), "Then it goes")
            app.terminate()
        }
    }

    /// A tab keeps its place: a chat left for Ideas opens again from Chat, not the agent's Bot Chat.
    /// The chat is another agent's, so Ideas makes that agent the one in use; once the board
    /// switches back, Chat opens that agent's Bot Chat.
    @MainActor
    func testChatOpensTheChatYouLeftForABoard() {
        let app = launchOnTheAgentsChat()
        let left = message("Here's the plan for Saturday.", in: app)
        openListedChat("demo-session-1", in: app)
        XCTAssertTrue(left.waitForExistence(timeout: 10))

        app.buttons["tab.ideas"].tap()
        XCTAssertTrue(left.waitForNonExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(left.waitForExistence(timeout: 10), "Chat opens the chat you left")
        XCTAssertFalse(message(botChatText, in: app).exists)
        save("tab-keeps-chat", app)

        app.buttons["tab.ideas"].tap()
        let name = app.buttons["agent.hero.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        let finance = app.buttons["agent.switcher.agent.finance"]
        XCTAssertTrue(finance.waitForExistence(timeout: 5))
        finance.tap()
        XCTAssertTrue(finance.waitForNonExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(message(botChatText, in: app).waitForExistence(timeout: 10),
                      "Chat opens the chat of the agent in use")
        XCTAssertFalse(left.exists)
    }

    /// With Sessions in the bar, a chat picked from its list is Sessions': Sessions opens it again,
    /// a second tap shows the list, and Chat opens the agent's own chat.
    @MainActor
    func testSessionsOpensTheChatYouLeftFromItsList() {
        let app = launchOnTheAgentsChat(layout: "{pinned=(sessions,ideas,feed);menu=();}")
        let sessions = app.buttons["tab.session-list"].firstMatch
        XCTAssertTrue(sessions.waitForExistence(timeout: 10))
        sessions.tap()
        let left = message(listedChatText, in: app)
        openListedChat(in: app)
        XCTAssertTrue(left.waitForExistence(timeout: 10))

        app.buttons["tab.ideas"].tap()
        XCTAssertTrue(left.waitForNonExistence(timeout: 5))
        sessions.tap()
        XCTAssertTrue(left.waitForExistence(timeout: 10), "Sessions opens the chat you left")
        save("sessions-keeps-chat", app)
        sessions.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].waitForExistence(timeout: 5),
                      "Sessions again shows the list")

        openListedChat(in: app)
        XCTAssertTrue(left.waitForExistence(timeout: 10))
        app.buttons["tab.ideas"].tap()
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(message(botChatText, in: app).waitForExistence(timeout: 10), "Chat is the agent's own chat")
    }

    /// With several gateways, All sessions' rows have the long-press menu too.
    @MainActor
    func testAllSessionsRowsHaveALongPressMenu() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let chats = app.buttons["menu.chats"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 5))
        chats.tap()
        let row = app.buttons["fleet.chat.Market scan"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Another computer's chat is listed")
        row.press(forDuration: 1.0)
        let rename = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                      "fleet.chat.rename", "Rename")).firstMatch
        let archive = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       "fleet.chat.archive", "Archive")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename on long press")
        XCTAssertTrue(archive.exists, "Archive on long press")
        save("all-sessions-menu", app)
    }

    @MainActor
    private func launch(_ experience: String?, appearance: String = "light") -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-canonical-agent-chat",
                               "-loopdy.demo.appearance", appearance]
        if let experience { app.launchArguments += ["-bighelp.chat.bot-chat-experience", experience] }
        app.launch()
        return app
    }

    /// A finance chat in the list that isn't its Bot Chat.
    private let listedChatText = "Booked! The details are in your email."

    /// Chat opening the agent's own chat, as people have it, and one computer.
    @MainActor
    private func launchOnTheAgentsChat(layout: String? = nil) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-canonical-agent-chat",
                               "-loopdy.home.opens-chat", "YES", "-bighelp.hosts.all-hosts", "NO"]
        if let layout { app.launchArguments += ["-bighelp.app-layout", layout] }
        app.launch()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 30))
        return app
    }

    /// A chat from the full list: ☰ › Sessions, or the Sessions tab when it's open. `demo-session-3`
    /// is the finance agent's, `demo-session-1` the travel agent's.
    @MainActor
    private func openListedChat(_ id: String = "demo-session-3", in app: XCUIApplication) {
        let row = app.buttons["session.row.\(id)"].firstMatch
        let list = app.descendants(matching: .any)["sessions.screen"]
        if !list.waitForExistence(timeout: 3) {
            let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.menu", "home.drawer.open"]))
                .firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            app.buttons["menu.sessions"].tap()
        }
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        row.tap()
    }

    @MainActor
    private func message(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func tapAgent(_ id: String, in app: XCUIApplication) {
        openRootTab("tab.agents", in: app)
        let agent = app.buttons["agent.\(id)"].firstMatch
        XCTAssertTrue(agent.waitForExistence(timeout: 10), "agent.\(id) on Agents")
        agent.tap()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_BOT_CHAT_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("bot-chat-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
