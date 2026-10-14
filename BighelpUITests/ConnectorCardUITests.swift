import XCTest

/// Hermes' connect card in chat, and Settings › Apps.
final class ConnectorCardUITests: BighelpUITestCase {
    /// `-test-connector-card`: two requests wait inline in one chat (made-up names). Each answer goes
    /// to Hermes, and a card leaves the chat once every row has its answer.
    @MainActor
    func testCardsWaitInlineAndAnswerHermes() {
        let app = makeApp()
        app.launchArguments = ["-test-connector-card"]
        app.launch()
        let apps = app.descendants(matching: .any)["connector.card.op-apps"].firstMatch
        let tool = app.descendants(matching: .any)["connector.card.op-tool"].firstMatch
        XCTAssertTrue(apps.waitForExistence(timeout: 20), "The apps request shows in the chat")
        XCTAssertTrue(tool.exists, "A second request shows beside it, not behind it")
        XCTAssertTrue(app.buttons["connector.card.connect.example_mail"].exists, "A sign-in link shows Connect")
        XCTAssertTrue(app.buttons["connector.card.retry.example_notes"].exists, "An expired link shows Try again")
        evidence("cards", app)

        let approve = app.buttons["connector.card.approve.weather"]
        scrollTo(approve, in: app)
        XCTAssertFalse(approve.isEnabled, "An install waits for the value it needs")
        let key = app.secureTextFields["connector.card.env.WEATHER_API_KEY"]
        key.tap()
        key.typeText("made-up-key")
        approve.tap()
        let answers = app.staticTexts["connector.fixture.answers"]
        XCTAssertTrue(answers.waitForLabel(containing: "connection.respond weather", timeout: 5), "Install answered")
        XCTAssertTrue(tool.waitForNonExistence(timeout: 5), "The answered request leaves the chat")
        XCTAssertTrue(apps.exists, "The other request still waits")

        app.buttons["connector.card.skip.example_mail"].tap()
        app.buttons["connector.card.skip.example_notes"].tap()
        XCTAssertTrue(answers.waitForLabel(containing: "example_notes", timeout: 5), "Each skip answered")
        XCTAssertTrue(apps.waitForNonExistence(timeout: 5), "Every row answered: the card leaves")
    }

    /// Settings › Apps in demo mode: set up once, then connect an app.
    @MainActor
    func testAppsInSettings() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            settingsRow("settings.apps", in: app).tap()
            let setUp = app.buttons["connector.apps.set-up"]
            if setUp.waitForExistence(timeout: 5) {
                evidence("apps-intro-\(appearance)", app)
                setUp.tap()
            }
            let mail = app.buttons["connector.apps.app.example_mail"]
            XCTAssertTrue(mail.waitForExistence(timeout: 10), "The connected app is listed")
            evidence("apps-list-\(appearance)", app)
            let notes = app.buttons["connector.apps.app.example_notes"]
            if notes.waitForExistence(timeout: 3) {
                notes.tap()
                app.buttons["connector.apps.connect"].tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "connector.apps.account.")).firstMatch
                    .waitForExistence(timeout: 10), "The new account shows")
                evidence("apps-connected-\(appearance)", app)
            }
            app.terminate()
        }
    }

    /// A real Hermes (0.21.4 or later) asks to add an MCP tool and the card shows. Skip answers, so
    /// nothing is installed. It runs in a new chat; delete it on the host afterwards. Set (as TEST_RUNNER_…):
    /// - BIGHELP_CONNECTOR_HOST: an open host, e.g. 127.0.0.1:9121
    /// - BIGHELP_CONNECTOR_MODEL: a /model line for the chat, e.g. "gpt-6-luna --provider openai-codex --session"
    /// - BIGHELP_CONNECTOR_TOOL: an MCP catalog entry, e.g. "fetch"
    /// - BIGHELP_UI_EVIDENCE: a folder for screenshots (optional)
    @MainActor
    func testARealHostsCardShows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_CONNECTOR_HOST"], let tool = environment["BIGHELP_CONNECTOR_TOOL"] else {
            throw XCTSkip("Set BIGHELP_CONNECTOR_HOST and BIGHELP_CONNECTOR_TOOL")
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: host)
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The agent's chat opens")
        // A new chat: the home chat is the person's own, and /model pins the chat it runs in.
        chatNewChatButton(in: app).tap()
        confirmNewChatPicker(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "A new chat opens")
        sleep(3)
        if let model = environment["BIGHELP_CONNECTOR_MODEL"] {
            send("/model \(model)", in: app)
            sleep(10)
        }
        send("Use manage_connections with action install for the MCP catalog server \"\(tool)\" "
             + "(connectors: [{\"name\": \"\(tool)\", \"mcp\": true}]). Do nothing else, then tell me the result in one line.",
             in: app)
        let skip = app.buttons["connector.card.skip.\(tool)"]
        let shown = skip.waitForExistence(timeout: 150)
        evidence("host-card-\(shown ? "shown" : "missing")", app)
        XCTAssertTrue(shown, "Hermes' connect card shows in the chat")
        guard shown else {
            // Without the card Hermes waits out its 5 minutes; show what the agent says after.
            sleep(200)
            evidence("host-after-deadline", app)
            return
        }
        scrollTo(skip, in: app)
        skip.tap()
        XCTAssertTrue(skip.waitForNonExistence(timeout: 10), "Skip settles the card at once")
        sleep(20)
        evidence("host-after-skip", app)
    }

    // MARK: - Steps

    /// Sends and waits until the text has left the message box: a tap while the last turn is
    /// still finishing can leave it there.
    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText(text)
        let sent = NSPredicate(format: "NOT (value CONTAINS %@)", String(text.prefix(24)))
        for _ in 0..<4 {
            app.buttons["chat.send"].tap()
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: sent, object: composer)], timeout: 15)
                == .completed { return }
        }
        XCTFail("The message was sent")
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "connector-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("connector-\(name).png"))
    }
}

private extension XCUIElement {
    func waitForLabel(containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
            == .completed
    }
}
