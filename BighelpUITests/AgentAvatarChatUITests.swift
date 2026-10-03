import XCTest

/// Opt-in: saves two looks for a demo agent and screenshots its chat after
/// each, which showed the older look before. Set BIGHELP_AVATAR_CHAT_EVIDENCE
/// (TEST_RUNNER_BIGHELP_AVATAR_CHAT_EVIDENCE) to the output folder.
final class AgentAvatarChatUITests: BighelpUITestCase {
    @MainActor
    func testChatShowsTheLookYouJustSaved() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_AVATAR_CHAT_EVIDENCE"] != nil else {
            throw XCTSkip("Set BIGHELP_AVATAR_CHAT_EVIDENCE to capture the walkthrough.")
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark",
                               "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        openAgents(in: app)

        design(accessory: "crown", in: app)
        save("01-agents-crown", app)
        openChat(in: app)
        save("02-chat-crown", app)
        back(in: app)

        design(accessory: "headset", in: app)
        save("03-agents-headset", app)
        openChat(in: app)
        save("04-chat-headset", app)
    }

    // MARK: Helpers

    @MainActor
    private func design(accessory: String, in app: XCUIApplication) {
        let tile = app.descendants(matching: .any)["agents.featured.finance"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        tile.press(forDuration: 0.8)
        tap(app.buttons["agent.finance.edit"])
        tap(app.buttons["agent.editor.design-avatar"])
        XCTAssertTrue(app.buttons["avatar.creator.use"].waitForExistence(timeout: 10))
        let cloud = app.buttons["avatar.creator.character.cloud"]
        for _ in 0..<5 where !cloud.isHittable { app.swipeUp() }
        tap(cloud)
        tap(app.buttons["avatar.creator.tab.extras"])
        let item = app.buttons["avatar.creator.accessory.\(accessory)"]
        for _ in 0..<4 where !item.isHittable { app.swipeUp() }
        tap(item)
        tap(app.buttons["avatar.creator.use"])
        let saveButton = app.buttons["agent.editor.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        sleep(3)
        saveButton.tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        sleep(2)
    }

    @MainActor
    private func openChat(in app: XCUIApplication) {
        tap(app.descendants(matching: .any)["agents.featured.finance"].firstMatch)
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer-shell"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)
    }

    @MainActor
    private func back(in app: XCUIApplication) {
        // An agent's chat from Agents is the Chat tab's: ☰ leads back to Agents.
        tap(app.buttons["chat.menu"])
        tap(app.buttons["menu.agents"])
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func openAgents(in app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25))
        menu.tap()
        tap(app.buttons["menu.agents"])
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_CHAT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
