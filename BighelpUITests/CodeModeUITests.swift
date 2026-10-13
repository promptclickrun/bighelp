import XCTest

/// Bighelp IDE on the demo data: chosen as the start mode it is the home, each send
/// starts its own session card without leaving the screen, and ☰ switches back to
/// Bighelp Chat. Set BIGHELP_CODE_MODE_EVIDENCE (TEST_RUNNER_BIGHELP_CODE_MODE_EVIDENCE)
/// to a folder to save screenshots; BIGHELP_CODE_MODE_APPEARANCE picks light or dark.
final class CodeModeUITests: BighelpUITestCase {
    @MainActor
    func testSendsStartSessionsBackToBackAndMenuSwitchesModes() throws {
        let app = makeApp()
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_CODE_MODE_APPEARANCE"] ?? "dark"
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code",
                               "-loopdy.demo.appearance", appearance]
        app.launch()

        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 10), "Bighelp IDE opens as the home.")
        XCTAssertTrue(app.buttons["code.chip.project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["code.chip.project"].label.contains("bighelp"), "The first project is picked.")
        save("01-home", app)

        // Two sends in a row: each one is its own session, and the screen stays.
        send("Fix the widget tap when the host is asleep", in: app)
        send("Tighten the Usage chart spacing", in: app)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "code.session."))
        let deadline = Date().addingTimeInterval(10)
        while cards.count < 2, Date() < deadline { usleep(200_000) }
        XCTAssertEqual(cards.count, 2, "Each send adds its own session card.")
        XCTAssertTrue(element("code.screen", in: app).exists, "Sending doesn't leave the Code home.")
        save("02-two-sessions", app)

        app.buttons["code.chip.placement"].tap()
        // A menu item's name is its title and subtitle together.
        let local = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local checkout")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 3), "Where it runs offers the local checkout.")
        save("03-where-it-runs", app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New worktree")).firstMatch.tap()

        app.buttons["code.chip.branch"].tap()
        XCTAssertTrue(element("code.branches", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["code.branch.main"].exists, "Worktrees start from the default branch.")
        save("04-branch", app)
        app.buttons["code.branch.done"].tap()

        app.buttons["code.chip.project"].tap()
        XCTAssertTrue(element("code.projects", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["code.project.bighelp-plugin"].exists)
        save("05-project", app)
        app.buttons["Done"].firstMatch.tap()

        // A card opens its session's chat, with no bottom bar; ☰ › Sessions returns to the Bighelp IDE home.
        cards.element(boundBy: 0).tap()
        XCTAssertTrue(element("chat.composer-shell", in: app).waitForExistence(timeout: 8), "The card opens its chat.")
        XCTAssertFalse(app.buttons["tab.feed"].exists, "Bighelp IDE's chats have no bottom bar.")
        save("06-session", app)
        app.buttons["chat.menu"].tap()
        app.buttons["menu.code.sessions"].tap()
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 5))

        // ☰: the mode switch on top and Code's places; Bighelp Chat brings the chat home back.
        app.buttons["home.drawer.open"].tap()
        XCTAssertTrue(element("menu.experience", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu.code.pull-requests"].exists)
        XCTAssertTrue(app.buttons["menu.code.worktrees"].exists)
        XCTAssertFalse(app.buttons["menu.agents"].exists, "Bighelp IDE's ☰ lists its own places.")
        save("07-menu", app)
        app.buttons["Bighelp Chat"].tap()
        XCTAssertTrue(element("code.screen", in: app).waitForNonExistence(timeout: 5), "Bighelp Chat leaves Code.")
    }

    /// Out of the box there's no Bighelp IDE: no switch in ☰.
    @MainActor
    func testCodeModeIsOffByDefault() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        app.buttons["home.drawer.open"].firstMatch.tap()
        XCTAssertTrue(element("navigation.menu", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("menu.experience", in: app).exists)
        XCTAssertTrue(app.buttons["menu.agents"].exists)
    }

    @MainActor
    private func send(_ message: String, in app: XCUIApplication) {
        let field = element("code.composer.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(message)
        app.buttons["code.composer.send"].tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CODE_MODE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
