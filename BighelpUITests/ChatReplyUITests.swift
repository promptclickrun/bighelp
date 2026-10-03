import XCTest

/// Long-press › Reply on demo data: the composer quotes the message, the sent
/// message draws the quote above its bubble (not the quote line), and ✕
/// cancels. Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ChatReplyUITests: BighelpUITestCase {
    @MainActor
    func testReplyToTheAgentSendsAQuotedMessage() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let agentMessage = message(in: app, from: "Avery Park: Room for the conversation")
            XCTAssertTrue(agentMessage.waitForExistence(timeout: 8))
            longPress(agentMessage)
            for existing in ["Copy to clipboard", "Select text"] {
                XCTAssertTrue(action(existing, in: app).waitForExistence(timeout: 3), "\(existing) stays in the menu")
            }
            action("Reply", in: app).tap()

            let bar = app.descendants(matching: .any)["chat.reply-draft.quote"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 3), "The composer quotes the message")
            XCTAssertTrue(bar.label.contains("Replying to Avery Park"), bar.label)
            XCTAssertTrue(bar.label.contains("Room for the conversation."), bar.label)
            let editor = app.textViews["chat.composer.text"]
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Reply opens the keyboard")
            editor.typeText("Love it")
            evidence("composer-\(appearance)")

            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            send.tap()
            XCTAssertTrue(bar.waitForNonExistence(timeout: 5), "Sending clears the reply")
            let sent = message(in: app, from: "You: Love it")
            XCTAssertTrue(sent.waitForExistence(timeout: 5), "The bubble shows only what was typed")
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "[Replying to"))
                .firstMatch.exists, "No raw quote line on screen")
            let quote = app.descendants(matching: .any)["chat.message.reply-quote"].firstMatch
            XCTAssertTrue(quote.waitForExistence(timeout: 3), "The quote shows above the sent message")
            XCTAssertTrue(quote.label.contains("Replying to Avery Park"), quote.label)
            XCTAssertLessThan(quote.frame.maxY, sent.frame.maxY)
            evidence("sent-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testReplyToYourOwnMessageAndCancel() {
        let app = launch(appearance: "light")
        let mine = message(in: app, from: "You: A calmer chat")
        XCTAssertTrue(mine.waitForExistence(timeout: 8))
        longPress(mine)
        action("Reply", in: app).tap()
        let bar = app.descendants(matching: .any)["chat.reply-draft.quote"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        XCTAssertTrue(bar.label.contains("Replying to yourself"), bar.label)
        app.buttons["chat.reply-draft.cancel"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 3), "✕ cancels the reply")
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    /// Chat text views are labelled "Sender: text".
    @MainActor
    private func message(in app: XCUIApplication, from prefix: String) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
                                           "chat.message.inline-selection", prefix)).firstMatch
    }

    @MainActor
    private func longPress(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)
    }

    @MainActor
    private func action(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        _ = element.waitForExistence(timeout: 3)
        return element
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-reply-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-reply-\(name).png"))
    }
}
