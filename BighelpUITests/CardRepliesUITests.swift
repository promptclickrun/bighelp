import XCTest

/// Answering a card sends the answer to the agent as the person's next
/// message, and whatever they were typing stays in the composer.
/// Set BIGHELP_CARD_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class CardRepliesUITests: BighelpUITestCase {
    @MainActor
    func testPickingAnOptionAndSendingAFormReachTheAgent() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-card-replies", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()

        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Hold this thought")
        app.swipeDown(velocity: .fast)

        // The chat opens at the bottom; the selection card is above the form.
        let mountains = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "The mountains")).firstMatch
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        for _ in 0..<5 where !(mountains.exists && mountains.isHittable) {
            (timeline.exists ? timeline : app).swipeDown()
        }
        XCTAssertTrue(mountains.waitForExistence(timeout: 5))
        mountains.tap()
        let send = app.buttons["chat.generative-ui.selection.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.generative-ui.selection.sent"].waitForExistence(timeout: 5))
        let pick = app.textViews.matching(NSPredicate(format: "value == %@", "Let's go to the mountains.")).firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "The pick is the person's next message")
        XCTAssertEqual(editor.value as? String, "Hold this thought", "The draft stays in the composer")
        save("selection-sent", app)

        let openForm = app.buttons["chat.generative-ui.form.open"]
        for _ in 0..<4 where !openForm.isHittable { app.swipeUp() }
        openForm.tap()
        let pace = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose")).firstMatch
        XCTAssertTrue(pace.waitForExistence(timeout: 5))
        pace.tap()
        app.buttons["Slow and easy"].firstMatch.tap()
        let sendForm = app.buttons["chat.generative-ui.form.send"]
        for _ in 0..<4 where !(sendForm.exists && sendForm.isHittable) { app.swipeUp() }
        sendForm.tap()

        let answers = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "My answers to “Trip details”")).firstMatch
        XCTAssertTrue(answers.waitForExistence(timeout: 5))
        let text = answers.value as? String ?? ""
        XCTAssertTrue(text.contains("Travelers: 2"), text)
        XCTAssertTrue(text.contains("Pace: Slow and easy"), text)
        XCTAssertEqual(editor.value as? String, "Hold this thought")
        save("form-sent", app)
    }

    /// A form's limits show under their fields, the date picker offers only the days
    /// they allow, and an answer outside them sends nothing until it's fixed.
    @MainActor
    func testFormLimitsShowAndHoldBackAnAnswerOutsideThem() throws {
        for appearance in ["light", "dark"] {
            try checkFormLimits(appearance: appearance)
        }
    }

    @MainActor
    private func checkFormLimits(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-card-replies", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()

        let openForm = app.buttons["chat.generative-ui.form.open"]
        XCTAssertTrue(openForm.waitForExistence(timeout: 10))
        for _ in 0..<4 where !openForm.isHittable { app.swipeUp() }
        openForm.tap()
        XCTAssertTrue(app.staticTexts["Between 1 and 8"].waitForExistence(timeout: 5))

        // The card allows November 6 to 27, 2026.
        let leaving = app.datePickers.firstMatch
        XCTAssertTrue(leaving.waitForExistence(timeout: 5))
        leaving.tap()
        let calendar = app.buttons["PopoverDismissRegion"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "The calendar opens")
        XCTAssertFalse(app.buttons["Thursday, November 5"].isEnabled)
        XCTAssertFalse(app.buttons["Saturday, November 28"].isEnabled)
        app.buttons["Friday, November 13"].tap()
        save("\(appearance)-form-date-limits", app)
        calendar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        XCTAssertTrue(calendar.waitForNonExistence(timeout: 5))

        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose")).firstMatch.tap()
        app.buttons["Slow and easy"].firstMatch.tap()
        func travelers(_ value: String) -> XCUIElement {
            app.textFields.matching(NSPredicate(format: "value == %@", value)).firstMatch
        }
        XCTAssertTrue(travelers("2").waitForExistence(timeout: 5))
        travelers("2").tap()
        travelers("2").typeText(XCUIKeyboardKey.delete.rawValue + "12")
        let sendForm = app.buttons["chat.generative-ui.form.send"]
        for _ in 0..<4 where !(sendForm.exists && sendForm.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Up to 300 characters"].exists)
        sendForm.tap()

        let refused = app.staticTexts["Complete the required fields with valid values."]
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "12 travelers is outside 1 to 8")
        XCTAssertTrue(sendForm.exists, "The form stays open and sends nothing")
        save("\(appearance)-form-refused", app)

        for _ in 0..<4 where !travelers("12").isHittable { app.swipeDown() }
        travelers("12").tap()
        travelers("12").typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "3")
        for _ in 0..<4 where !(sendForm.exists && sendForm.isHittable) { app.swipeUp() }
        sendForm.tap()

        let answers = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "My answers to “Trip details”")).firstMatch
        XCTAssertTrue(answers.waitForExistence(timeout: 5))
        let text = answers.value as? String ?? ""
        XCTAssertTrue(text.contains("Travelers: 3"), text)
        XCTAssertTrue(text.contains("Leaving: November 13, 2026"), text)
        app.terminate()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["BIGHELP_CARD_EVIDENCE"] != nil else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "card-replies-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
