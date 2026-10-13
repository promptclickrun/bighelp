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

    /// A tap outside the message box puts the keyboard away, on an empty home and
    /// between session cards (it used to stay up until you scrolled just right).
    @MainActor
    func testTappingOutsideTheMessageBoxClosesTheKeyboard() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code"]
        app.launch()
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 10))
        let field = element("code.composer.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "The empty home closes the keyboard.")

        send("Fix the widget tap", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Space under the cards closes the keyboard.")
    }

    /// `/` lists the new session's commands, a picked command starts the session as one,
    /// and the plan it writes opens rendered from the chat and from Changes. The mode
    /// button's Plan does the same for a plain message.
    @MainActor
    func testSlashCommandsModesAndPlansOpenRendered() throws {
        let app = makeApp()
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_CODE_MODE_APPEARANCE"] ?? "dark"
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 10))

        let field = element("code.composer.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("/")
        XCTAssertTrue(element("code.slash", in: app).waitForExistence(timeout: 5), "/ opens the commands list.")
        XCTAssertTrue(element("code.slash.row.plan", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("code.slash.row.review", in: app).exists, "Skills list too.")
        save("08-slash", app)
        element("code.slash.row.plan", in: app).tap()
        XCTAssertTrue(element("code.slash", in: app).waitForNonExistence(timeout: 3), "A pick closes the list.")
        XCTAssertEqual(field.value as? String, "/plan ")
        field.typeText("Add a loading state to Usage")
        app.buttons["code.composer.send"].tap()

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "code.session."))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        cards.firstMatch.tap()
        XCTAssertTrue(element("chat.composer-shell", in: app).waitForExistence(timeout: 8))
        let planLink = app.links.matching(NSPredicate(format: "label CONTAINS %@", "usage-loading-state.md")).firstMatch
        XCTAssertTrue(planLink.waitForExistence(timeout: 10), "The plan's path in the reply is a link.")
        planLink.tap()
        XCTAssertTrue(element("markdown-file.rendered", in: app).waitForExistence(timeout: 5), "The plan opens rendered.")
        XCTAssertTrue(app.staticTexts["Usage loading state"].exists, "Its heading shows as a heading, not as # text.")
        save("09-plan-from-chat", app)
        app.buttons["markdown-file.edit"].tap()
        XCTAssertTrue(element("markdown-file.editor", in: app).waitForExistence(timeout: 3), "Edit shows the text.")
        app.buttons["markdown-file.cancel"].tap()
        app.buttons["markdown-file.done"].tap()
        app.buttons["chat.menu"].tap()
        app.buttons["menu.code.sessions"].tap()
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 5))

        XCTAssertTrue(cards.firstMatch.label.contains("Add a loading state to Usage"))
        XCTAssertFalse(cards.firstMatch.label.contains("/plan"), "The command isn't part of the card's name.")

        // The mode button: Plan for a plain message.
        app.buttons["code.composer.mode"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Plan")).firstMatch.tap()
        XCTAssertEqual(app.buttons["code.composer.mode"].label, "Mode: Plan")

        // A long model chip ("GPT-5.6 Mini · X-High · Fast") truncates; the buttons beside it keep their place.
        app.buttons["code.composer.model"].tap()
        app.buttons["code.runtime.model"].tap()
        let mini = app.buttons["code.runtime.model.openai.gpt-5.6-mini"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        app.navigationBars["Model"].buttons.element(boundBy: 0).tap()
        app.buttons["code.runtime.reasoning"].tap()
        app.buttons["X-High"].firstMatch.tap()
        app.buttons["code.runtime.fast"].tap()
        app.buttons["On"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        let model = app.buttons["code.composer.model"]
        let mode = app.buttons["code.composer.mode"]
        let sendButton = app.buttons["code.composer.send"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        XCTAssertEqual(model.label, "Model: GPT-5.6 Mini · X-High · Fast")
        XCTAssertLessThanOrEqual(model.frame.maxX, mode.frame.minX + 1, "The model name stops before the mode button.")
        XCTAssertLessThanOrEqual(mode.frame.maxX, sendButton.frame.minX + 1)
        XCTAssertTrue(sendButton.isHittable)
        save("10-mode", app)

        // Changes: the plan file opens on its rendered preview.
        cards.firstMatch.press(forDuration: 1.0)
        app.buttons["Changes"].firstMatch.tap()
        XCTAssertTrue(element("code.changes", in: app).waitForExistence(timeout: 5))
        let planFile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "usage-loading-state.md")).firstMatch
        XCTAssertTrue(planFile.waitForExistence(timeout: 5))
        planFile.tap()
        XCTAssertTrue(element("markdown-file.rendered", in: app).waitForExistence(timeout: 5), "Changes opens the preview.")
        XCTAssertTrue(app.buttons["Changes"].exists || element("code.diff.mode", in: app).exists)
        save("11-plan-in-changes", app)
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
