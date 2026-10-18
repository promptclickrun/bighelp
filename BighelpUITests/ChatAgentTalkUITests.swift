import XCTest

/// Agents messaging each other on demo data (`-test-agent-talk`): back-to-back
/// `hermes -p … chat` calls make one rail outside the finished turn's fold, a
/// message another agent sent in is a rail instead of the person's bubble, a
/// running call says what the other agent is doing, and a tap shows what the
/// agents said. The rails stay with tool calls hidden. Set
/// BIGHELP_AGENT_TALK_EVIDENCE (TEST_RUNNER_…) to a folder to save the screenshots.
final class ChatAgentTalkUITests: BighelpUITestCase {
    @MainActor
    func testAgentsTalkingShowAsRailsOutsideTheFold() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))

            let live = rail(in: app, label: "Mina Shah is searching the web…")
            XCTAssertTrue(live.waitForExistence(timeout: 10), "The running call says what the other agent is doing")
            let incoming = rail(in: app, label: "2 messages with Jordan Lee")
            XCTAssertTrue(incoming.exists, "Jordan's message is a rail")
            XCTAssertFalse(text(in: app, containing: "Message from 🤖 Jordan").exists,
                           "Another agent's message never shows as the person's bubble")

            let finished = rail(in: app, label: "4 messages with Mina Shah and Jordan Lee")
            reveal(finished, in: timeline)
            let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked for")).firstMatch
            XCTAssertTrue(fold.exists)
            XCTAssertTrue(fold.label.contains("2 steps"), "Messages to agents aren't steps: \(fold.label)")
            XCTAssertLessThan(fold.frame.minY, finished.frame.minY, "The rail stays out of the fold, after it")
            save("agent-talk-rails-\(appearance)", app)

            finished.tap()
            let answer = text(in: app, containing: "About $3,100 for two")
            XCTAssertTrue(answer.waitForExistence(timeout: 5), "The sheet shows what Mina said")
            XCTAssertTrue(text(in: app, containing: "What would 4 nights in Lisbon").exists, "and what Avery asked")
            XCTAssertTrue(text(in: app, containing: "Sam from the neighbor list").exists, "and Jordan's answer")
            XCTAssertFalse(text(in: app, containing: "session_id").exists)
            let steps = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.agent-talk.steps.")).firstMatch
            XCTAssertTrue(steps.waitForExistence(timeout: 5), "Mina's own chat says what she did")
            steps.tap()
            XCTAssertTrue(text(in: app, containing: "Searched the web").waitForExistence(timeout: 5))
            save("agent-talk-sheet-\(appearance)", app)
            app.buttons["chat.agent-talk.done"].tap()
            XCTAssertTrue(finished.waitForExistence(timeout: 5))

            reveal(live, in: timeline, towardOlder: false)
            live.tap()
            XCTAssertTrue(text(in: app, containing: "Is there a hotel under $200").waitForExistence(timeout: 5))
            XCTAssertTrue(text(in: app, containing: "Mina Shah is searching the web").exists)
            save("agent-talk-sheet-live-\(appearance)", app)
            app.buttons["chat.agent-talk.done"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testRailsStayWithToolCallsHidden() throws {
        let app = launch(appearance: "light", extra: ["-test-hide-tool-calls"])
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        XCTAssertTrue(rail(in: app, label: "Mina Shah is searching the web…").waitForExistence(timeout: 10))
        let finished = rail(in: app, label: "4 messages with Mina Shah and Jordan Lee")
        reveal(finished, in: timeline)
        XCTAssertTrue(finished.exists)
        save("agent-talk-tools-hidden-light", app)
    }

    @MainActor
    func testRailsShowInSimpleBotMode() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-bighelp.settings.simple-bots", "YES"])
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 15))
            XCTAssertTrue(rail(in: app, label: "Mina Shah is searching the web…").waitForExistence(timeout: 10))
            let finished = rail(in: app, label: "4 messages with Mina Shah and Jordan Lee")
            reveal(finished, in: timeline)
            XCTAssertTrue(finished.exists)
            save("agent-talk-simple-\(appearance)", app)
            finished.tap()
            XCTAssertTrue(text(in: app, containing: "About $3,100 for two").waitForExistence(timeout: 5))
            save("agent-talk-simple-sheet-\(appearance)", app)
            app.terminate()
        }
    }

    /// An agent another one asked works in its own Hermes process. Opening its chat then shows it
    /// typing with Stop, and Stop ends that run.
    @MainActor
    func testAChatBusyInAnotherProcessShowsWorkingAndStops() throws {
        let app = makeApp()
        // The usual demo chat, idle on this device; another process is running it.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-other-process-run", "-loopdy.demo.appearance", "dark"]
        app.launch()
        let typing = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Sending."))
            .firstMatch
        XCTAssertTrue(typing.waitForExistence(timeout: 15), "The agent shows as working")
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isEnabled, "Stop reaches the other process")
        save("agent-talk-other-process-dark", app)
        stop.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: typing)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["chat.stop"].exists, "Back to an idle chat")
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-agent-talk", "-loopdy.chat.foldCompletedTurns", "YES",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func rail(in app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "chat.agent-talk.", label)).firstMatch
    }

    /// Chat text is a text view; sheet rows combine their words into one label.
    @MainActor
    private func text(in app: XCUIApplication, containing words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    /// Scrolls toward the element: older content is above.
    @MainActor
    private func reveal(_ element: XCUIElement, in timeline: XCUIElement, towardOlder: Bool = true) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            if element.exists, element.frame.minY > timeline.frame.midY {
                timeline.swipeUp(velocity: .slow)
            } else if towardOlder {
                timeline.swipeDown(velocity: .slow)
            } else {
                timeline.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AGENT_TALK_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
