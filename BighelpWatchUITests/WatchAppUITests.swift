import XCTest

/// The Watch app on its demo data (`-watch-demo`): no iPhone or host.
/// Set BIGHELP_WATCH_EVIDENCE (TEST_RUNNER_BIGHELP_WATCH_EVIDENCE) to save screenshots.
final class WatchAppUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHomeShowsNeedsChatsAndTheAgentsBoard() {
        let app = launch()
        XCTAssertTrue(app.buttons["watch.talk"].waitForExistence(timeout: 10), "Talk to your agent comes first")
        save("01-home", app)
        XCTAssertTrue(reveal("watch.need.need-publish", in: app), "Approvals come right after Talk")
        save("01b-home-needs", app)
        XCTAssertTrue(reveal("watch.chat.demo-budget", in: app), "Recent chats follow")
        save("02-home-chats", app)
        XCTAssertTrue(reveal("watch.board.feed", in: app))
        XCTAssertTrue(reveal("watch.board.goals", in: app), "Feed, Ideas and Goals are there")
        save("03-home-board", app)
    }

    @MainActor
    func testApprovingFromTheWatch() {
        let app = launch()
        XCTAssertTrue(reveal("watch.need.need-publish", in: app))
        element("watch.need.need-publish", in: app).tap()
        let approve = app.buttons["watch.decide.once"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["npm publish --tag beta\nPublishes version 2.4.0-beta.1 of the site kit."].exists
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'npm publish'")).firstMatch.exists,
                      "The approval says exactly what it's for")
        save("04-approval", app)
        approve.tap()
        XCTAssertTrue(app.buttons["watch.talk"].waitForExistence(timeout: 8), "It goes back home once sent")
        XCTAssertFalse(reveal("watch.need.need-publish", in: app), "An answered approval leaves the list")
    }

    @MainActor
    func testWiderApprovalsAskAgain() {
        let app = launch()
        XCTAssertTrue(reveal("watch.need.need-publish", in: app))
        element("watch.need.need-publish", in: app).tap()
        let session = app.buttons["watch.decide.session"]
        XCTAssertTrue(reveal("watch.decide.session", in: app))
        session.tap()
        XCTAssertTrue(app.staticTexts["Your bot won't ask again in this chat."].waitForExistence(timeout: 5),
                      "Approving for the whole chat asks first")
        save("05-approval-confirm", app)
    }

    @MainActor
    func testAnsweringAQuestionWithAChoice() {
        let app = launch()
        XCTAssertTrue(reveal("watch.need.need-date", in: app))
        element("watch.need.need-date", in: app).tap()
        let choice = app.buttons["Friday the 17th"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        save("06-question", app)
        choice.tap()
        XCTAssertTrue(app.buttons["watch.talk"].waitForExistence(timeout: 8))
        XCTAssertFalse(reveal("watch.need.need-date", in: app))
    }

    @MainActor
    func testReplyingInAChatGetsAnAnswer() {
        let app = launch()
        XCTAssertTrue(reveal("watch.chat.demo-budget", in: app))
        element("watch.chat.demo-budget", in: app).tap()
        XCTAssertTrue(text(containing: "It comes to $2,400", in: app).waitForExistence(timeout: 8),
                      "The chat shows its latest messages")
        save("07-chat", app)
        let reply = app.buttons["watch.reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.tap()
        enter("Trim ads to 1200", in: app)
        XCTAssertTrue(text(containing: "Trim ads to 1200", in: app).waitForExistence(timeout: 8), "Your reply shows")
        XCTAssertTrue(text(containing: "On it.", in: app).waitForExistence(timeout: 10), "The agent's answer follows")
        save("08-chat-answered", app)
    }

    /// A chat the agent is working in says what it's doing, in the phone's words.
    @MainActor
    func testAWorkingChatSaysWhatTheAgentIsDoing() {
        let app = launch()
        XCTAssertTrue(reveal("watch.chat.demo-sink", in: app))
        element("watch.chat.demo-sink", in: app).tap()
        XCTAssertTrue(text(containing: "Searching the web…", in: app).waitForExistence(timeout: 8),
                      "The running tool's plain words show while the agent works")
        save("10-chat-working", app)
    }

    @MainActor
    func testTalkStartsANewChat() {
        let app = launch()
        let talk = app.buttons["watch.talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 10))
        talk.tap()
        enter("Remind me to call the bank", in: app)
        XCTAssertTrue(text(containing: "Remind me to call the bank", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(text(containing: "On it.", in: app).waitForExistence(timeout: 10), "A new chat gets an answer")
        save("09-new-chat", app)
    }

    @MainActor
    func testFeedItemOpensAndCanGoToThePhone() {
        let app = launch()
        XCTAssertTrue(reveal("watch.board.feed", in: app))
        element("watch.board.feed", in: app).tap()
        let item = element("watch.item.f1", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 8))
        save("10-feed", app)
        item.tap()
        XCTAssertTrue(text(containing: "184 sign-ups", in: app).waitForExistence(timeout: 5), "The item's text shows")
        XCTAssertTrue(reveal("watch.open-on-iphone", in: app))
        save("11-feed-item", app)
        app.buttons["watch.open-on-iphone"].tap()
        XCTAssertTrue(text(containing: "Check your iPhone", in: app).waitForExistence(timeout: 5))
    }

    /// The real path: this Watch asks bighelp on the paired iPhone simulator,
    /// which runs on its demo data. Start the iPhone app first with
    /// `-use-demo-fixtures -disable-demo-delays` and set BIGHELP_WATCH_LIVE_PHONE.
    @MainActor
    func testThroughThePairedIPhone() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_WATCH_LIVE_PHONE"] != nil else {
            throw XCTSkip("Needs the paired iPhone simulator running Bighelp")
        }
        let app = XCUIApplication()
        app.launch()
        let talk = app.buttons["watch.talk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 40), "The iPhone answers with its agents")
        save("20-live-home", app)
        let chat = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'watch.chat.'")).firstMatch
        for _ in 0..<12 where !(chat.exists && chat.isHittable) { XCUIDevice.shared.rotateDigitalCrown(delta: 0.4) }
        XCTAssertTrue(chat.exists, "The iPhone's chats show")
        save("21-live-chats", app)
        XCUIDevice.shared.rotateDigitalCrown(delta: -3)
        talk.tap()
        enter("What's on my plate today?", in: app)
        XCTAssertTrue(text(containing: "What's on my plate today?", in: app).waitForExistence(timeout: 30),
                      "The message reaches a new chat on the iPhone")
        save("22-live-sent", app)
        XCTAssertTrue(element("watch.message.agent", in: app).waitForExistence(timeout: 40),
                      "The agent's reply comes back from the iPhone")
        save("23-live-answer", app)
        app.buttons["watch.open-on-iphone"].tap()
        XCTAssertTrue(text(containing: "Check your iPhone", in: app).waitForExistence(timeout: 20),
                      "The iPhone opens the chat")
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-watch-demo"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func text(containing value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    /// Scrolls until the element is on screen.
    @MainActor
    private func reveal(_ id: String, in app: XCUIApplication) -> Bool {
        let target = element(id, in: app)
        _ = target.waitForExistence(timeout: 3)
        // With the Digital Crown, from the top: rows off screen aren't built,
        // and a swipe down can open a system screen over the app.
        if !(target.exists && target.isHittable) { XCUIDevice.shared.rotateDigitalCrown(delta: -3) }
        for _ in 0..<12 where !(target.exists && target.isHittable) {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.4)
        }
        return target.exists && target.isHittable
    }

    /// Types into the system text input and sends it.
    @MainActor
    private func enter(_ value: String, in app: XCUIApplication) {
        let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The text input opens")
        field.tap()
        field.typeText(value)
        for label in ["Done", "Send", "Return"] where app.buttons[label].exists {
            app.buttons[label].tap()
            return
        }
        field.typeText("\n")
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WATCH_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
