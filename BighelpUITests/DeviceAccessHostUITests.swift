import XCTest

/// Device access cards on a real, isolated Hermes with the bighelp plugin and a scripted model, started
/// by `Scripts/HostSignInMatrixProbe.py --modes device --plugin <plugin checkout>` (BIGHELP_SIGNIN_PROBE).
/// The app runs without demo fixtures, as on a phone, with every Device access switch off. The model
/// calls `iphone_reminders` (or `iphone_calendar`); the chat shows the card, and the agent's reply says
/// what its own call got back. Skipped without the probe.
///
/// `testHowDidISleepThisWeekReadsAppleHealth` is the flow App Review follows; it reads the simulator's own
/// Health data, so add some sleep there first if the answer should have a chart.
final class DeviceAccessHostUITests: BighelpUITestCase {
    @MainActor
    func testAToolThatIsOffAsksWithACardAndTheCallGoesOn() throws {
        let app = try openNewChat()
        send("device access test reminders", in: app)
        let card = element("device-access.card.reminders", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 60), "The agent's call to Reminders, which is off, shows a card")
        save("device-1-card", app)
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        allowIfIOSAsks()
        XCTAssertTrue(card.waitForNonExistence(timeout: 30))
        XCTAssertTrue(message(containing: "Device access fixture: completed", in: app).waitForExistence(timeout: 60),
                      "The call that asked went on and its answer reached the agent")
        save("device-2-came-back", app)

        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let form = app.descendants(matching: .any)["settings.permissions"].firstMatch
        let toggle = app.switches["permissions.device-tools.reminders"].firstMatch
        for _ in 0..<6 where !toggle.exists || !toggle.isHittable { form.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1", "The card turned on the same switch")
        save("device-3-switch-on", app)
    }

    @MainActor
    func testNotNowGivesTheAgentAPlainRefusal() throws {
        let app = try openNewChat()
        send("device access test calendar", in: app)
        let card = element("device-access.card.calendar", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        app.buttons["device-access.card.not-now"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
        XCTAssertTrue(message(containing: "Device access fixture: failed permission_declined", in: app)
            .waitForExistence(timeout: 60), "The agent hears a plain refusal")
        save("device-4-declined", app)
        // The same tool again in this chat: no second card, the same refusal at once.
        send("device access test calendar again", in: app)
        let answers = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "permission_declined", "permission_declined"))
        expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: answers)
        waitForExpectations(timeout: 60)
        XCTAssertFalse(card.exists, "The card does not come back in that chat")
        save("device-5-no-second-card", app)
    }

    /// What App Review follows (guideline 2.5.1): Apple Health in Settings › Device access, then "How did I
    /// sleep this week?" in a chat. The card turns Health on, the one-time note says where the data goes,
    /// iOS's own Health sheet asks, and the agent answers with a chart of what Health gave. Reads the
    /// simulator's own Health data; run it with a few nights of sleep added there, and record the screen.
    @MainActor
    func testHowDidISleepThisWeekReadsAppleHealth() throws {
        let app = try openNewChat()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        let health = app.switches["permissions.device-tools.health"].firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 10), "Apple Health is in Device access")
        XCTAssertEqual(health.value as? String, "0")
        sleep(3)
        save("sleep-1-device-access", app)
        closeSettings(in: app)

        send("How did I sleep this week?", in: app)
        let card = element("device-access.card.health", in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 60), "The agent asks for Apple Health with a card")
        sleep(2)
        save("sleep-2-card", app)
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        XCTAssertTrue(element("device-access.card.health-sharing", in: app).waitForExistence(timeout: 10))
        sleep(3)
        save("sleep-3-sharing-note", app)
        app.buttons["device-access.card.turn-on"].firstMatch.tap()
        allowHealthSheet(in: app)
        XCTAssertTrue(card.waitForNonExistence(timeout: 60))
        XCTAssertTrue(message(containing: "Apple Health", in: app).waitForExistence(timeout: 60),
                      "The read shows as an Apple Health step")
        // A chart of the nights Health gave, or a plain answer when it gave none.
        let answered = NSPredicate { _, _ in
            self.message(containing: "You slept about", in: app).exists
                || self.message(containing: "Apple Health shared no sleep", in: app).exists
        }
        wait(for: [expectation(for: answered, evaluatedWith: nil)], timeout: 90)
        sleep(4)
        save("sleep-4-answer", app)
    }

    /// iOS's Health sheet: turn on every kind bighelp asks for, then Allow.
    @MainActor private func allowHealthSheet(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for root in [app, springboard] {
            let all = root.descendants(matching: .any)["Turn On All"].firstMatch
            guard all.waitForExistence(timeout: 15) else { continue }
            sleep(2)
            all.tap()
            sleep(1)
            let allow = root.buttons["Allow"].firstMatch
            if allow.waitForExistence(timeout: 5) { allow.tap() }
            return
        }
    }

    // MARK: Helpers

    @MainActor private func openNewChat() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes device")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "device" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        // Every data-sharing switch off for this run, whatever the simulator saved before.
        app.launchArguments = ["-loopdy.home.opens-chat", "YES", "-bighelp.device-tools.grants", "()"]
        app.launch()
        let composer = app.textViews["chat.composer.text"]
        if !composer.waitForExistence(timeout: 10) {
            try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The agent's chat opens")
        let newChat = chatNewChatButton(in: app)
        if newChat.waitForExistence(timeout: 5) {
            newChat.tap()
            confirmNewChatPicker(in: app)
        }
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        return app
    }

    /// The probe grants Reminders on the simulator, so iOS usually doesn't ask; when it does, allow it.
    @MainActor private func allowIfIOSAsks() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText(text)
        app.buttons["chat.send"].tap()
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor private func message(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
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
