import XCTest

/// A real Hermes runs a background command, ends the turn, and starts a turn of its own when the command
/// finishes. Both turns fold as Card says, never as raw steps. It runs in a new chat; delete it on the host
/// afterwards. Set (as TEST_RUNNER_…):
/// - BIGHELP_BACKGROUND_HOST: an open host, e.g. 127.0.0.1:9121
/// - BIGHELP_BACKGROUND_MODEL: a /model line for the chat, e.g. "gpt-6-luna --provider openai-codex --session"
/// - BIGHELP_UI_EVIDENCE: a folder for screenshots (optional)
final class BackgroundWorkHostUITests: BighelpUITestCase {
    @MainActor
    func testABackgroundCommandsTurnsFoldAsCardSays() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_BACKGROUND_HOST"] else { throw XCTSkip("Set BIGHELP_BACKGROUND_HOST") }
        let app = makeApp()
        app.launchArguments = ["-bighelp.chat.work-style", "card"]
        app.launch()
        try onboardOpenHost(app, address: host)
        let composer = app.textViews["chat.composer.text"]
        // A new chat: the Bot Chat is the person's own, and /model pins the chat it runs in.
        let newChat = chatNewChatButton(in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 30), "Setup lands on the home")
        newChat.tap()
        confirmNewChatPicker(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "A new chat opens")
        sleep(3)
        if let model = environment["BIGHELP_BACKGROUND_MODEL"] {
            send("/model \(model)", in: app)
            sleep(10)
        }
        send("Use the terminal tool with background=true and notify_on_complete=true to run exactly this command: "
             + "sleep 20; echo finished-ok . Do not use delegate_task. Right after starting it, reply only with the word: started.",
             in: app)
        sleep(12)
        evidence("after-start", app)
        // Hermes' own turn about the result answers with the command's output. The prompt has the same
        // words, so the answer is a second message with them.
        let mentions = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "finished-ok"))
        let answered = NSPredicate { _, _ in mentions.count >= 2 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: answered, object: nil)], timeout: 120),
                       .completed, "Hermes reports the finished command")
        sleep(8)
        evidence("after-finish", app)
        let folds = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.completed-turn:"))
        XCTAssertGreaterThanOrEqual(folds.count, 1, "The finished turns fold into Card's \"Worked for…\" line")
    }

    // MARK: - Steps

    /// Sends and waits until the text has left the message box.
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
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "background-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("background-\(name).png"))
    }
}
