import XCTest

/// An agent's screen on a real Hermes 0.22 Linux host with a password sign-in: Start
/// screen, watch, take control, click and type, hand back, close, turn it off. Skipped
/// unless set (as TEST_RUNNER_…):
/// - BIGHELP_BOT_SCREEN_HOST: the host's address, e.g. http://127.0.0.1:9131
/// - BIGHELP_BOT_SCREEN_USERNAME and BIGHELP_BOT_SCREEN_PASSWORD: the dashboard sign-in
/// - BIGHELP_BOT_SCREEN_TAP: where to click while in control, as fractions of the screen ("0.5,0.98")
/// - BIGHELP_BOT_SCREEN_TYPE: text to type after that click, with "\n" for Return
/// - BIGHELP_BOT_SCREEN_EVIDENCE: a folder for screenshots (optional)
/// It also runs on a Release build linked with `-Wl,-stack_size,0x100000` (the iPhone's 1 MB main-thread
/// stack): there the app starts at the real welcome, which this test walks through.
final class BotScreenHostUITests: BighelpUITestCase {
    @MainActor
    func testStartWatchTakeControlHandBackAndStop() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_BOT_SCREEN_HOST"], let user = environment["BIGHELP_BOT_SCREEN_USERNAME"],
              let password = environment["BIGHELP_BOT_SCREEN_PASSWORD"] else {
            throw XCTSkip("Set BIGHELP_BOT_SCREEN_HOST, _USERNAME and _PASSWORD")
        }
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Not Now", "Continue"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-loopdy.home.opens-chat", "YES", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        signIn(app, host: host, user: user, password: password)

        let avatar = app.buttons["agent.hero.avatar"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 30))
        avatar.tap()
        let screenTab = app.buttons["agent.profile.tab.screen"]
        XCTAssertTrue(screenTab.waitForExistence(timeout: 20), "Hermes 0.22 answers display.status")
        screenTab.tap()

        let start = app.buttons["agent.screen.start"]
        let preview = app.buttons["agent.screen.preview"]
        if start.waitForExistence(timeout: 5) {
            save("1-off", app)
            start.tap()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 90), "The screen started")
        sleep(5) // the first still
        save("2-preview", app)

        app.buttons["agent.screen.open"].tap()
        let title = app.staticTexts["screen.viewer.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let takeControl = app.buttons["screen.viewer.take-control"]
        let live = NSPredicate { _, _ in takeControl.exists && takeControl.isEnabled }
        wait(for: [expectation(for: live, evaluatedWith: nil)], timeout: 30)
        XCTAssertTrue(title.label.hasSuffix("is in control"), title.label)
        sleep(2)
        save("3-watching", app)

        takeControl.tap()
        let handBack = app.buttons["screen.viewer.hand-back"]
        XCTAssertTrue(handBack.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "You're in control")
        let canvas = app.descendants(matching: .any)["screen.viewer.canvas"].firstMatch
        if let tap = environment["BIGHELP_BOT_SCREEN_TAP"]?.split(separator: ",").compactMap({ Double($0) }), tap.count == 2 {
            point(on: canvas, x: tap[0], y: tap[1]).tap()
            sleep(3)
        }
        if let text = environment["BIGHELP_BOT_SCREEN_TYPE"] {
            app.buttons["screen.viewer.keyboard"].tap()
            let tip = app.buttons["Continue"].firstMatch
            if tip.waitForExistence(timeout: 2) { tip.tap() }
            app.typeText(text.replacingOccurrences(of: "\\n", with: "\n"))
            sleep(3)
            app.buttons["screen.viewer.keyboard"].tap()
        }
        sleep(2)
        save("4-in-control", app)

        handBack.tap()
        XCTAssertTrue(takeControl.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.hasSuffix("is in control"), title.label)
        app.buttons["screen.viewer.close"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        sleep(5)
        save("5-after", app)

        app.buttons["agent.screen.turn-off"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 30), "Turned off")
        save("6-turned-off", app)
    }

    /// The aspect-fit screen inside the canvas, so fractions land on the screen, not the margins.
    @MainActor private func point(on canvas: XCUIElement, x: Double, y: Double) -> XCUICoordinate {
        let frame = canvas.frame
        let aspect = 16.0 / 10.0
        let width = min(frame.width, frame.height * aspect)
        let height = width / aspect
        let originX = (frame.width - width) / 2
        let originY = (frame.height - height) / 2
        return canvas.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: originX + width * x, dy: originY + height * y))
    }

    @MainActor private func signIn(_ app: XCUIApplication, host: String, user: String, password: String) {
        let address = app.textFields["host-setup.address"]
        if !address.waitForExistence(timeout: 8) {
            let start = app.buttons["onboarding.get-started"]
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            start.tap()
            agreeToAIDataIfAsked(app)
        }
        XCTAssertTrue(address.waitForExistence(timeout: 20))
        address.tap()
        address.typeText(host)
        tapConnect(app)
        let username = app.textFields["direct-hermes.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 45), "The host asks for its sign-in")
        username.tap()
        // Return drops the keyboard, which covers the password box during onboarding.
        username.typeText(user + "\n")
        let secret = app.secureTextFields["direct-hermes.password"]
        secret.tap()
        // Return ends editing: iOS's Passwords bar sits over Connect while the box has focus.
        secret.typeText(password + "\n")
        tapConnect(app)
        let next = app.buttons.matching(NSPredicate(format: "identifier IN %@ AND (label == %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], "Start chatting", "Let")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        // During onboarding the button reports the screen's identifier.
        let connect = app.buttons.matching(NSPredicate(format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_BOT_SCREEN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
