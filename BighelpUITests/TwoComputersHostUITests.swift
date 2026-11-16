import XCTest

/// Two real, isolated computers in one bighelp, with Show every computer on (#1045). They take the
/// place of the tests that went with the old all-hosts screen. Each is skipped without its probe.
///
/// - Secure input in a chat on the computer that isn't in use
///   (`Scripts/HostSignInMatrixProbe.py --modes fleet`). Afterwards the probe reads both computers and
///   fails unless only the bot's own computer saved the value.
/// - A group chat with a bot from each computer, made in New chat
///   (`Scripts/RoomLinkProbe.py --simulator-id`: both computers run their gateway, which serves RoomLink).
///
/// BIGHELP_SIGNIN_EVIDENCE (TEST_RUNNER_…) saves screenshots.
final class TwoComputersHostUITests: BighelpUITestCase {
    /// The agent on the other computer asks for a secret: the masked pop-up shows over its chat, the
    /// agent hears it was saved, and the value never shows in the chat. Before, a chat the app had
    /// switched computers for refused the request at once and the person never saw the pop-up.
    @MainActor func testSecureInputInAChatOnTheOtherComputer() throws {
        let app = try launchWithBothComputers(mode: "fleet")
        // Lab Hermes was added last and is in use. Desk agent is on the other computer.
        showBots(in: app)
        let desk = bot("Desk agent", in: app)
        XCTAssertTrue(desk.waitForExistence(timeout: 60), "Bots lists the other computer's bot")
        XCTAssertTrue(bot("Lab agent", in: app).waitForExistence(timeout: 30), "And the bot of the computer in use")
        save("secure-1-both-computers", app)
        desk.tap()

        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 90), "The chat opens on the bot's own computer")
        send("secure input test", composer: composer, in: app)
        let field = app.secureTextFields["direct-hermes.secure-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 45), "The secure pop-up shows over the other computer's chat")
        save("secure-2-pop-up", app)
        field.tap()
        field.typeText("fixture-value-not-a-secret")
        app.buttons["direct-hermes.secure-submit"].tap()
        XCTAssertTrue(message("Secure input fixture: saved.", in: app).waitForExistence(timeout: 45),
                      "The agent got the value, not a refusal")
        XCTAssertFalse(message("fixture-value-not-a-secret", in: app).exists, "The value never shows in the chat")
        save("secure-3-saved", app)
    }

    /// New chat with a bot from each computer and one message: the group chat opens on the computer in
    /// use, the other computer's bot joins through its own computer, and both answer under their names.
    @MainActor func testAGroupChatWithABotFromEachComputerAnswers() throws {
        let app = try launchWithBothComputers(mode: "roomlink")
        showBots(in: app)
        XCTAssertTrue(bot("Desk agent", in: app).waitForExistence(timeout: 60), "Bots lists the other computer's bot")

        app.buttons["home.new-chat"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat.to"].firstMatch.waitForExistence(timeout: 15))
        // The first pick's computer is the group chat's home.
        for name in ["Lab agent", "Desk agent"] {
            let person = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH 'new-chat.bot.' AND label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(person.waitForExistence(timeout: 30), "New chat lists \(name)")
            person.tap()
            let chip = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'new-chat.to.chip.' AND label == %@", name)).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 10), "\(name) is in the To row")
        }
        save("group-1-picked", app)

        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        send("Everyone, say hello", composer: composer, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["new-chat.to"].firstMatch.waitForNonExistence(timeout: 90),
                      "The group chat takes New chat's place")
        let refusal = app.alerts.firstMatch
        XCTAssertFalse(refusal.exists, "The group chat was made: \(refusal.exists ? refusal.label : "")")

        let replies = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Hello from this agent."))
        expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: replies)
        waitForExpectations(timeout: 240)
        // Each computer calls its bot "default": each reply keeps its own bot's name.
        for name in ["Lab agent", "Desk agent"] {
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "\(name): Hello from this agent.")).firstMatch
            XCTAssertTrue(row.exists, "\(name)'s reply carries its own name")
        }
        save("group-2-both-answered", app)
    }

    // MARK: Setup

    /// Sets up both of the probe's computers and returns the app on its home, with Show every
    /// computer on. The second computer (Lab Hermes) ends in use.
    @MainActor private func launchWithBothComputers(mode: String) throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes fleet or Scripts/RoomLinkProbe.py --simulator-id")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == mode else { throw XCTSkip("These computers run the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-test-no-configured-hosts", "-bighelp.hosts.all-hosts", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address_a"]))
        try addAnotherOpenHost(app, address: try XCTUnwrap(probe["address_b"]))
        return app
    }

    /// A bot on the Bots view by its name, on whichever computer: its id there carries its computer.
    @MainActor private func bot(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'simple-bots.' AND label BEGINSWITH %@", name))
            .firstMatch
    }

    @MainActor private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["chat.send"]
        let deadline = Date().addingTimeInterval(30)
        while !send.isEnabled, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        send.tap()
    }

    /// A message in the chat: its text is a text view, never a static text.
    @MainActor private func message(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("two-computers-\(name).png"))
    }
}
