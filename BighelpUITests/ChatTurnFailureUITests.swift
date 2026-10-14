import XCTest

/// Failed turns in the demo (`-test-turn-failure`): the real native chat gets
/// a Hermes-shaped failed final, and its card says what went wrong and offers
/// the fix. The model picker it opens shows how much of each plan is left.
final class ChatTurnFailureUITests: BighelpUITestCase {
    @MainActor
    func testALimitOffersATimedRetryAndAnotherModelWithPlanLeft() throws {
        try limit(appearance: "light")
    }

    @MainActor
    func testALimitInDarkMode() throws {
        try limit(appearance: "dark")
    }

    @MainActor
    private func limit(appearance: String) throws {
        continueAfterFailure = false
        let app = launch(code: "rate_limit", appearance: appearance)
        sendFirstMessage(app)

        let card = app.descendants(matching: .any)["chat.turn-failure"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The failed turn shows its card.")
        let sentence = app.staticTexts["chat.turn-failure.sentence"]
        XCTAssertTrue(sentence.label.hasPrefix("You've reached your limit. It resets at "), sentence.label)
        let timed = app.buttons["chat.turn-failure.fix.try-again-at"]
        XCTAssertTrue(timed.exists)
        XCTAssertTrue(timed.label.hasPrefix("Try again at "), timed.label)
        let another = app.buttons["chat.turn-failure.fix.model"]
        XCTAssertEqual(another.label, "Use another model")
        capture(app, "\(appearance)-1-limit")

        // Use another model: the chat's picker, with what's left of each plan.
        another.tap()
        let selected = app.descendants(matching: .any)["chat.models.selected"].firstMatch
        let opened = selected.waitForExistence(timeout: 10)
        capture(app, "\(appearance)-2-picker")
        XCTAssertTrue(opened, "Use another model opens Model & reasoning.")
        let openAI = app.buttons["chat.models.filter.provider.openai"]
        XCTAssertTrue(openAI.waitForExistence(timeout: 10))
        openAI.tap()
        let row = app.buttons["chat.models.row.openai:gpt-5.6"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("17% left · resets "), row.label)
        capture(app, "\(appearance)-3-plan-left")
        app.buttons["chat.models.filter.provider.anthropic"].tap()
        let limited = app.buttons["chat.models.row.anthropic:claude-opus-4.1"]
        XCTAssertTrue(limited.waitForExistence(timeout: 5))
        XCTAssertTrue(limited.label.contains("Limited until "), limited.label)
        capture(app, "\(appearance)-4-plan-limited")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        // Try again at the reset: the card counts down, and Cancel stops it.
        timed.tap()
        let scheduled = app.staticTexts["chat.turn-failure.scheduled"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 5))
        XCTAssertTrue(scheduled.label.hasPrefix("Sends again at "), scheduled.label)
        XCTAssertFalse(timed.isEnabled, "It's already waiting.")
        capture(app, "\(appearance)-5-scheduled")
        app.buttons["chat.turn-failure.cancel-scheduled"].tap()
        XCTAssertFalse(scheduled.waitForExistence(timeout: 2))
        XCTAssertTrue(timed.isEnabled)
    }

    @MainActor
    func testTryAgainSendsTheMessageAgainAndTheReplyArrives() throws {
        continueAfterFailure = false
        let app = launch(code: "agent_init_failed", appearance: "light")
        sendFirstMessage(app)
        let card = app.descendants(matching: .any)["chat.turn-failure"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["chat.turn-failure.sentence"].label,
                       "Hermes couldn't start the agent. Check that an AI provider is set up.")
        XCTAssertTrue(app.buttons["chat.turn-failure.fix.providers"].exists)
        capture(app, "light-5-could-not-start")

        app.buttons["chat.turn-failure.fix.try-again"].tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", "a quiet ryokan", "a quiet ryokan")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "The second try's reply arrives.")
        XCTAssertFalse(card.exists, "The card goes once the next turn starts.")
        let sent = app.descendants(matching: .any).matching(NSPredicate(
            format: "value == %@ OR label == %@", "Plan a quiet weekend in Kyoto", "Plan a quiet weekend in Kyoto"))
        XCTAssertEqual(sent.count, 1, "Try again doesn't add a second copy of the message.")
        capture(app, "light-6-tried-again")
    }

    @MainActor
    func testSignInProblemsOpenAIProviders() throws {
        continueAfterFailure = false
        let app = launch(code: "auth", appearance: "dark")
        sendFirstMessage(app)
        let sentence = app.staticTexts["chat.turn-failure.sentence"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 15))
        XCTAssertEqual(sentence.label, "Sign-in to Demo Cloud stopped working.")
        XCTAssertFalse(app.buttons["chat.turn-failure.fix.try-again"].exists, "Trying again unchanged would fail again.")
        capture(app, "dark-7-sign-in")
        app.buttons["chat.turn-failure.fix.sign-in"].tap()
        let opened = app.staticTexts["turn-failure-fixture.opened"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        XCTAssertTrue(opened.label.contains("AI providers"), opened.label)
    }

    @MainActor
    func testATooLongChatOffersANewOne() throws {
        continueAfterFailure = false
        let app = launch(code: "context_overflow", appearance: "light")
        sendFirstMessage(app)
        let sentence = app.staticTexts["chat.turn-failure.sentence"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 15))
        XCTAssertEqual(sentence.label, "This chat is too long for the model.")
        app.buttons["chat.turn-failure.fix.new-chat"].tap()
        XCTAssertTrue(app.staticTexts["turn-failure-fixture.opened"].waitForExistence(timeout: 5))
        capture(app, "light-8-new-chat")
    }

    @MainActor
    private func launch(code: String, appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                "-test-turn-failure", code, "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func sendFirstMessage(_ app: XCUIApplication) {
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        composer.tap()
        composer.typeText("Plan a quiet weekend in Kyoto")
        app.buttons["chat.send"].tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "turn-failure-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_TURN_FAILURE_SHOTS"], !directory.isEmpty {
            try? shot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("turn-failure-\(name).png"))
        }
    }
}
