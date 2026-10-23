import XCTest

/// CarPlay's hands-free voice chat on the demo data: it starts a new chat
/// with the default agent and listens, mutes, ends, and starts again; Agents
/// picks who to talk to.
/// (The simulator's CarPlay window itself can't be opened from a test.)
final class CarPlayVoiceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTalkListensMutesAndEnds() {
        let app = launch()
        let phase = app.staticTexts["carplay.phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 15))

        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "It connects and listens: \(phase.label)")
        XCTAssertNotEqual(app.staticTexts["carplay.agent"].label, "your agent", "It talks to the default agent")

        app.buttons["carplay.mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5), "Mute holds the microphone")
        app.buttons["carplay.mute"].tap()

        app.buttons["carplay.end"].tap()
        XCTAssertTrue(wait(for: phase, label: "paused"), "End stops listening: \(phase.label)")

        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "Talk starts again: \(phase.label)")
    }

    @MainActor
    func testAgentsPickWhoToTalkToAndTalkContinuesTheChat() {
        let app = launch()
        let phase = app.staticTexts["carplay.phase"]
        let agent = app.staticTexts["carplay.agent"]
        let chat = app.staticTexts["carplay.chat"]
        XCTAssertTrue(phase.waitForExistence(timeout: 15))

        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "It listens with the default agent: \(phase.label)")
        let defaultAgent = agent.label
        let firstChat = chat.label
        XCTAssertNotEqual(firstChat, "none")

        // Agents ends listening and lists the agents, the current one marked.
        app.buttons["carplay.agents"].tap()
        XCTAssertTrue(wait(for: phase, label: "paused"), "Agents stops listening: \(phase.label)")
        let current = app.buttons["carplay.pick.finance"]
        XCTAssertTrue(current.waitForExistence(timeout: 10), "The agents are listed")
        XCTAssertTrue(current.label.contains("Current"), "The agent in use is marked: \(current.label)")
        XCTAssertTrue(current.label.contains("Default"), "The default agent is noted: \(current.label)")
        XCTAssertFalse(app.buttons["carplay.pick.travel"].label.contains("Current"))

        // Picking the same agent goes on in the same chat.
        current.tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "Picking starts talking: \(phase.label)")
        XCTAssertEqual(chat.label, firstChat, "The same agent keeps the same chat")

        // Talk after a pause goes on in the same chat.
        app.buttons["carplay.end"].tap()
        XCTAssertTrue(wait(for: phase, label: "paused"))
        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"))
        XCTAssertEqual(chat.label, firstChat, "Talk after a pause continues the chat")

        // Another agent starts a new chat.
        app.buttons["carplay.agents"].tap()
        let other = app.buttons["carplay.pick.travel"]
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "The new agent listens: \(phase.label)")
        XCTAssertNotEqual(agent.label, defaultAgent, "It talks to the picked agent")
        let secondChat = chat.label
        XCTAssertNotEqual(secondChat, firstChat, "Another agent starts a new chat")

        // A new car connection starts a new chat with the agent picked last.
        app.buttons["carplay.reconnect"].tap()
        app.buttons["carplay.talk"].tap()
        XCTAssertTrue(wait(for: phase, label: "listening"), "A new connection listens: \(phase.label)")
        XCTAssertEqual(agent.label, "Mina Shah", "The last pick is kept")
        XCTAssertNotEqual(chat.label, secondChat, "A new connection starts a new chat")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-carplay-session",
                               "-loopdy.voice.conversation-mode", "turnBased"]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    @MainActor
    private func wait(for element: XCUIElement, label: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
