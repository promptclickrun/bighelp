import XCTest

/// This chat › New Bot Chat on a real Hermes host with the bighelp plugin (a probe file naming an
/// open host and BIGHELP_BOT_CHAT_AGENT, an agent of its own). Its Bot Chat gets a turn, the app
/// leaves long enough to reconnect, then New Bot Chat: the old one becomes a regular chat and a
/// new Bot Chat opens. Hermes won't rename a hidden Bot Chat, which the app hid behind "Check the
/// connection". Skipped without the probe.
final class NewBotChatHostUITests: BighelpUITestCase {
    @MainActor func testNewBotChatAfterAReconnect() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BIGHELP_SIGNIN_PROBE"], let agent = environment["BIGHELP_BOT_CHAT_AGENT"] else {
            throw XCTSkip("Needs BIGHELP_SIGNIN_PROBE and BIGHELP_BOT_CHAT_AGENT")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        openRootTab("tab.agents", in: app)
        let row = app.buttons["agent.\(agent)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "agent.\(agent) on Agents")
        row.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "Its Bot Chat opens")
        composer.tap()
        composer.typeText("Reply with only the word plum in capital letters.")
        let send = app.buttons["chat.send"]
        let ready = Date().addingTimeInterval(30)
        while !send.isEnabled, Date() < ready { Thread.sleep(forTimeInterval: 0.3) }
        send.tap()
        let reply = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "PLUM")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "The agent answers")

        // Past the grace period the app closes its host connection; coming back reconnects.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(35)
        app.activate()
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "The Bot Chat is back")

        var newBotChat = chatMenuItem("chat.new-bot-chat", in: app)
        if !newBotChat.exists {
            newBotChat = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                          "chat.new-bot-chat", "New Bot Chat")).firstMatch
        }
        XCTAssertTrue(newBotChat.waitForExistence(timeout: 10), "This chat has New Bot Chat")
        save("new-bot-chat-menu", app)
        newBotChat.tap()
        let failed = app.alerts["Unable to open"]
        XCTAssertFalse(failed.waitForExistence(timeout: 20), "New Bot Chat starts: \(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(reply.waitForNonExistence(timeout: 30), "A new, empty Bot Chat replaces the old one")
        save("new-bot-chat-after", app)
        app.terminate()
    }

    /// The Bot Chat New Bot Chat made, after a turn, the app away past its grace and the agent
    /// tapped again: it opens with its turn, not "Unable to open" and a status that keeps flashing.
    @MainActor func testTheNewBotChatOpensAgainAfterLeaving() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BIGHELP_SIGNIN_PROBE"], let agent = environment["BIGHELP_BOT_CHAT_AGENT"] else {
            throw XCTSkip("Needs BIGHELP_SIGNIN_PROBE and BIGHELP_BOT_CHAT_AGENT")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let answer = environment["BIGHELP_BOT_CHAT_ANSWER"] ?? "PLUM"
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        func openAgent() {
            openRootTab("tab.agents", in: app)
            let row = app.buttons["agent.\(agent)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "agent.\(agent) on Agents")
            row.tap()
        }
        func send(_ text: String) -> XCUIElement {
            let composer = app.textViews["chat.composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 45), "The Bot Chat opens")
            composer.tap()
            composer.typeText(text)
            let send = app.buttons["chat.send"]
            let ready = Date().addingTimeInterval(30)
            while !send.isEnabled, Date() < ready { Thread.sleep(forTimeInterval: 0.3) }
            send.tap()
            let reply = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", answer)).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 90), "The agent answers")
            return reply
        }
        openAgent()
        _ = send("Reply with only the word plum in capital letters.")

        let newBotChat = chatMenuItem("chat.new-bot-chat", in: app)
        XCTAssertTrue(newBotChat.waitForExistence(timeout: 10), "This chat has New Bot Chat")
        newBotChat.tap()
        let failed = app.alerts["Unable to open"]
        XCTAssertFalse(failed.waitForExistence(timeout: 15), "New Bot Chat starts")
        let reply = send("Again: reply with only the word plum in capital letters.")
        save("new-bot-chat-turn", app)

        // Past the grace period the app closes its host connection; coming back reconnects.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(35)
        app.activate()
        save("new-bot-chat-back", app)
        XCTAssertFalse(failed.waitForExistence(timeout: 15),
                       "The chat comes back: \(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        openAgent()
        XCTAssertFalse(failed.waitForExistence(timeout: 20),
                       "The agent's Bot Chat opens: \(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "with its turn")
        let catchingUp = app.staticTexts["chat.hydration-status"]
        let settled = Date().addingTimeInterval(20)
        while catchingUp.exists, Date() < settled { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(catchingUp.exists, "and settles")
        save("new-bot-chat-reopened", app)
        if failed.exists { failed.buttons["OK"].tap() }

        // A new chat starts too: the same record stopped those.
        let newChat = chatNewChatButton(in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), "New chat is there")
        newChat.tap()
        confirmNewChatPicker(in: app)
        XCTAssertFalse(failed.waitForExistence(timeout: 20),
                       "A new chat starts: \(failed.staticTexts.allElementsBoundByIndex.map(\.label))")
        save("new-chat", app)
        app.terminate()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
