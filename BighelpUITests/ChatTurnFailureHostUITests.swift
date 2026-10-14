import XCTest

/// A failed turn on a real Hermes host explains itself: a host with no AI
/// provider fails every message with Hermes' own `error_surface`, and the chat
/// shows a plain sentence with a fix instead of a generic failure.
/// Set (as TEST_RUNNER_…):
/// - BIGHELP_FAILURE_HOST: a throwaway host with password sign-in and no provider, e.g. 127.0.0.1:9131
/// - BIGHELP_FAILURE_USERNAME, BIGHELP_FAILURE_PASSWORD: its made-up test login
/// - BIGHELP_FAILURE_APPEARANCE: light or dark (optional, light by default)
/// - BIGHELP_FAILURE_EVIDENCE: a folder for screenshots (optional)
final class ChatTurnFailureHostUITests: BighelpUITestCase {
    @MainActor
    func testAFailedTurnSaysWhatWentWrongAndOffersAFix() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_FAILURE_HOST"],
              let username = environment["BIGHELP_FAILURE_USERNAME"],
              let password = environment["BIGHELP_FAILURE_PASSWORD"] else {
            throw XCTSkip("Set BIGHELP_FAILURE_HOST, BIGHELP_FAILURE_USERNAME and BIGHELP_FAILURE_PASSWORD")
        }
        let appearance = environment["BIGHELP_FAILURE_APPEARANCE"] ?? "light"
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Not Now", "Continue"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-loopdy.demo.appearance", appearance]
        app.launch()

        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(host)
        tapConnect(app)
        let user = app.textFields["direct-hermes.username"]
        XCTAssertTrue(user.waitForExistence(timeout: 45), "The gated host asks for a username and password.")
        user.tap()
        user.typeText(username)
        let secret = app.secureTextFields["direct-hermes.password"]
        secret.tap()
        // Return ends editing: iOS's Passwords bar sits over Connect while the box has focus.
        secret.typeText(password + "\n")
        tapConnect(app)
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()

        let newChat = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["sessions.empty.new-chat", "chat.home.new-chat", "chat.new-chat", "root.new-chat"])).firstMatch
        if newChat.waitForExistence(timeout: 10) {
            newChat.tap()
            confirmNewChatPicker(in: app)
        }
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A chat opens after connecting")
        composer.tap()
        composer.typeText("Hello there")
        app.buttons["chat.send"].tap()

        let card = app.descendants(matching: .any)["chat.turn-failure"].firstMatch
        let shown = card.waitForExistence(timeout: 60)
        save("failure-\(appearance)-1-card", app)
        XCTAssertTrue(shown, "A failed turn shows what went wrong.")
        let sentence = app.staticTexts["chat.turn-failure.sentence"]
        XCTAssertTrue(sentence.exists)
        // Hermes couldn't start the agent: no provider is set up on this host.
        XCTAssertTrue(sentence.label.contains("set up"), sentence.label)
        let fix = app.buttons["chat.turn-failure.fix.providers"]
        XCTAssertTrue(fix.exists, "The card offers the fix: AI providers.")
        let again = app.buttons["chat.turn-failure.fix.try-again"]
        XCTAssertTrue(again.exists, "The card offers Try again.")

        // Try again runs the same message again; the host still has no provider.
        again.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 60), "The second try fails the same way and says so.")
        save("failure-\(appearance)-2-again", app)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR value == %@", "/retry", "/retry")).firstMatch.exists,
            "Try again doesn't show a command in the chat.")

        fix.tap()
        let providers = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS[c] %@", "provider")).firstMatch
        XCTAssertTrue(providers.waitForExistence(timeout: 20), "AI providers opens.")
        save("failure-\(appearance)-3-providers", app)
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_FAILURE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
