import XCTest

/// Settings › Chat › Bot chat experience decides what tapping an agent on Agents opens,
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
            XCTAssertTrue(newBotChat.waitForExistence(timeout: 5), "This chat › New Bot Chat in a Bot Chat")
            save("this-chat-\(appearance)", app)
            app.terminate()

            let settings = launch(nil, appearance: appearance)
            openSettings(in: settings)
            settingsRow("settings.menu.chat", in: settings).tap()
            let picker = settings.descendants(matching: .any)["settings.chat.bot-chat-experience"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.staticTexts["Persistent Bot Chat"].exists, "Persistent Bot Chat is the default")
            save("settings-\(appearance)", settings)
            settings.terminate()
        }
    }

    /// Compacting shows a chip above the message box, then Done with what it saved.
    @MainActor
    func testCompactionRailShowsThenFinishes() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                                   "-test-compaction-rail", "-loopdy.demo.appearance", appearance]
            app.launch()
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
