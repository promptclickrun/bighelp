import XCTest

/// The context window opens from the chat's ⋯ › Usage submenu,
/// as the same pop-up the ring above the message box used
/// to open. Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ChatContextWindowUITests: BighelpUITestCase {
    @MainActor
    func testContextWindowOpensFromTheChatMenu() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            XCTAssertFalse(app.buttons["chat.session-context"].exists, "No context button above the message box")

            _ = chatMenuItem("chat.context-window", in: app)
            if !menuButton("chat.context-window", "Context window", in: app).waitForExistence(timeout: 2) {
                menuButton("chat.options.usage", "Usage", in: app).tap()
            }
            let item = menuButton("chat.context-window", "Context window", in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "⋯ has Context window")
            let order = [menuButton("chat.provider-usage", "Usage", in: app, exact: true), item]
            for element in order { XCTAssertTrue(element.exists, element.identifier) }
            for (upper, lower) in zip(order, order.dropFirst()) {
                XCTAssertLessThan(upper.frame.midY, lower.frame.midY,
                                  "\(upper.identifier) comes before \(lower.identifier)")
            }
            evidence("menu-\(appearance)")

            item.tap()
            let popover = app.descendants(matching: .any)["chat.session-context.popover"].firstMatch
            XCTAssertTrue(popover.waitForExistence(timeout: 5), "The context pop-up opens")
            XCTAssertTrue(app.staticTexts["Context window"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["chat.session-context.latest-input"].exists, "Token rows")
            XCTAssertTrue(app.buttons["chat.model-summary"].exists, "The pop-up leads with the model")
            evidence("popover-\(appearance)")

            // Its provider usage button closes the pop-up and opens usage.
            app.buttons["chat.session-context.provider-usage"].tap()
            XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["provider-usage"].firstMatch.waitForExistence(timeout: 8),
                          "Provider usage opens from the pop-up")
            app.terminate()
        }
    }

    /// Model settings shows how full the context window is, under Thinking: plain words for
    /// everyone, and with Nerd Mode the token counts and a tap through to the Context page.
    @MainActor
    func testModelSettingsShowsTheContextWindow() {
        for nerdMode in [false, true] {
            let app = launch(appearance: nerdMode ? "dark" : "light",
                             extra: ["-loopdy.settings.nerd-mode", nerdMode ? "YES" : "NO"])
            let chip = app.buttons["chat.composer.model"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 10))
            chip.tap()
            let row = app.descendants(matching: .any)["chat.model-settings.context"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Model settings has the context window")
            let thinking = app.descendants(matching: .any)["chat.thinking"].firstMatch
            XCTAssertTrue(thinking.exists)
            XCTAssertLessThan(thinking.frame.maxY, row.frame.minY + 1, "It sits below the Thinking control")
            let value = row.value as? String ?? ""
            XCTAssertTrue(value.hasPrefix("25% used"), value)
            XCTAssertEqual(value.contains("tokens"), nerdMode, "Token counts are for Nerd Mode: \(value)")
            evidence("model-settings-\(nerdMode ? "nerd" : "plain")")

            if nerdMode {
                row.tap()
                XCTAssertTrue(app.descendants(matching: .any)["chat.session-context-breakdown"].firstMatch
                    .waitForExistence(timeout: 10), "The Context page opens")
                evidence("model-settings-context-page")
            } else {
                XCTAssertFalse(row.elementType == .button, "Without Nerd Mode it's a line to read, not a button")
            }
            app.terminate()
        }
    }

    /// Native menu rows can expose their title instead of their identifier.
    @MainActor
    private func menuButton(_ identifier: String, _ title: String, in app: XCUIApplication,
                            exact: Bool = false) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: exact ? "identifier == %@ OR label == %@"
                                                       : "identifier == %@ OR label BEGINSWITH %@",
                                         identifier, title)).firstMatch
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-v3-header-context", "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-context-window-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("chat-context-window-\(name).png"))
    }

    /// The Context page on a real Hermes host (a probe file naming an open host, and
    /// BIGHELP_BOT_CHAT_AGENT, an agent of its own on a model cleared for tests). A live chat's
    /// answer carries parts the demo's doesn't (Hermes 0.23 adds `context_files`), which the page
    /// once refused as "Context didn't load". Sends one short message in that agent's chat, and only
    /// when its model has the word in BIGHELP_HOST_MODEL_WORD. Skipped without the probe.
    @MainActor
    func testContextPageLoadsOnARealHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let probePath = environment["BIGHELP_SIGNIN_PROBE"], let agent = environment["BIGHELP_BOT_CHAT_AGENT"] else {
            throw XCTSkip("Needs BIGHELP_SIGNIN_PROBE and BIGHELP_BOT_CHAT_AGENT")
        }
        let probe = try JSONDecoder().decode([String: String].self,
                                             from: Data(contentsOf: URL(fileURLWithPath: probePath)))
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        openRootTab("tab.agents", in: app)
        let row = app.buttons["agent.\(agent)"].firstMatch
        if !row.waitForExistence(timeout: 20) {
            let search = app.descendants(matching: .any).matching(identifier: "agents.search").firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            app.typeText(agent + "\n")
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "agent.\(agent) on Agents")
        row.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "Its chat opens")

        // Only a model cleared for tests gets a message.
        let chip = app.buttons["chat.composer.model"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 20))
        // The chip's value names the model ("GPT 6 Luna, Medium").
        let model = chip.value as? String ?? ""
        guard let wanted = environment["BIGHELP_HOST_MODEL_WORD"]?.lowercased(), model.lowercased().contains(wanted) else {
            throw XCTSkip("The chat's model is \"\(model)\"; set BIGHELP_HOST_MODEL_WORD to a word of the model to use")
        }
        composer.tap()
        composer.typeText("Reply with only the word plum in capital letters.")
        let send = app.buttons["chat.send"]
        let ready = Date().addingTimeInterval(30)
        while !send.isEnabled, Date() < ready { Thread.sleep(forTimeInterval: 0.3) }
        // The chat may hold an earlier run's answer: wait for one more.
        let replies = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "PLUM"))
        let before = replies.count
        send.tap()
        let answered = Date().addingTimeInterval(120)
        while replies.count <= before, Date() < answered { Thread.sleep(forTimeInterval: 1) }
        XCTAssertGreaterThan(replies.count, before, "The agent answers")

        // The turn's usage arrives as it ends, a moment after its words.
        let context = app.descendants(matching: .any)["chat.model-settings.context"].firstMatch
        for attempt in 0..<4 where !context.exists {
            Thread.sleep(forTimeInterval: 6)
            chip.tap()
            if context.waitForExistence(timeout: 10) { break }
            evidence("host-model-settings-try-\(attempt)")
            let done = app.buttons["chat.model-settings.done"].firstMatch
            if done.exists { done.tap() }
        }
        XCTAssertTrue(context.exists, "Model settings has the context window after a turn")
        context.tap()
        let page = app.descendants(matching: .any)["chat.session-context-breakdown"].firstMatch
        let failed = app.staticTexts["Context didn't load"]
        let deadline = Date().addingTimeInterval(30)
        while !page.exists, !failed.exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        evidence("host-context-page")
        XCTAssertFalse(failed.exists, "The Context page must read a live chat's answer")
        XCTAssertTrue(page.exists, "The Context page shows the chat's context")
        app.terminate()
    }
}
