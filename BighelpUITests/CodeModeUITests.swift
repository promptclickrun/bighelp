import XCTest

/// Coding from New chat on the demo data (`DemoCodeProjectSource`, `DemoCodeGit`): with one bot
/// picked, the choices row under the message box picks a project, where it runs, the branch and the
/// mode; a coding send opens the project on Work, staged jobs go out with Send all as one batch,
/// and the project's ⋯ opens Dev Factory. Set BIGHELP_CODE_MODE_EVIDENCE
/// (TEST_RUNNER_BIGHELP_CODE_MODE_EVIDENCE) to a folder to save screenshots;
/// BIGHELP_CODE_MODE_APPEARANCE picks light or dark.
final class CodeModeUITests: BighelpUITestCase {
    @MainActor
    func testNewChatChoicesPickProjectWhereItRunsBranchAndMode() throws {
        let app = launch()
        pickProject("bighelp", in: app)
        save("01-project", app)

        app.buttons["new-chat.chip.placement"].tap()
        XCTAssertTrue(menuItem("new-chat.placement.local", title: "Local checkout", in: app).waitForExistence(timeout: 3),
                      "Where it runs offers the local checkout.")
        save("03-where-it-runs", app)
        menuItem("new-chat.placement.newWorktree", title: "New worktree", in: app).tap()

        app.buttons["new-chat.chip.branch"].tap()
        XCTAssertTrue(element("code.branches", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["code.branch.main"].exists, "Worktrees start from the default branch.")
        save("04-branch", app)
        app.buttons["code.branch.done"].tap()

        // The mode button: Plan for a plain message.
        reveal("new-chat.chip.mode", in: app).tap()
        let plan = menuItem("new-chat.mode.plan", title: "Plan", in: app)
        XCTAssertTrue(plan.waitForExistence(timeout: 3))
        save("04b-mode", app)
        plan.tap()
        // The chip takes the pick once the menu has closed.
        let picked = expectation(for: NSPredicate(format: "label == %@", "Mode: Plan"),
                                 evaluatedWith: app.buttons["new-chat.chip.mode"])
        wait(for: [picked], timeout: 5)

        app.buttons["new-chat.chip.project"].tap()
        let moreProjects = menuItem("new-chat.project.more", title: "More projects", in: app)
        XCTAssertTrue(moreProjects.waitForExistence(timeout: 3))
        moreProjects.tap()
        XCTAssertTrue(element("code.projects", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["code.project.bighelp-plugin"].exists)
        save("05-project-picker", app)
        app.buttons["Done"].firstMatch.tap()
    }

    /// A coding send starts its session without a chat of its own: the project's Work shows its card,
    /// and the card opens the session's chat.
    @MainActor
    func testACodingSendOpensItsProjectOnWork() throws {
        let app = launch()
        pickProject("bighelp", in: app)
        send("Fix the widget tap when the host is asleep", in: app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "work.item.coding:")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The send shows as its session's card.")
        save("02-session-card", app)
        card.tap()
        XCTAssertTrue(element("chat.composer-shell", in: app).waitForExistence(timeout: 8), "The card opens its chat.")
        save("06-session", app)
    }

    /// Orchestration: two staged jobs and the one in the box go out with Send all as one batch; its
    /// chat sends to every session, `#` lists the sessions and the project's open pull requests, and
    /// a mention sends to that session only.
    @MainActor
    func testStagedJobsSendAllAndTheBatchChat() throws {
        let app = launch()
        pickProject("bighelp", in: app)

        stage("Fix the widget tap when the host is asleep", in: app)
        XCTAssertTrue(element("new-chat.staged", in: app).waitForExistence(timeout: 3), "Stage keeps it in the tray.")
        stage("Add a loading state to the Usage page", in: app)
        XCTAssertTrue(element("new-chat.staged.job.2", in: app).exists)
        let field = app.textViews["chat.composer.text"]
        field.tap()
        field.typeText("Write tests for the branch name helper")
        let sendAll = app.buttons["new-chat.staged.send-all"]
        XCTAssertEqual(sendAll.label, "Send all 3")
        save("12-staged", app)
        sendAll.tap()

        // Send all opens the project's Work, with the batch as one card.
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "work.item.batch:")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The batch shows as one card.")
        XCTAssertFalse(element("new-chat.staged", in: app).exists, "Send all empties the tray.")
        let deadline = Date().addingTimeInterval(15)
        while card.label.contains("Starting"), Date() < deadline { usleep(300_000) }
        save("13-batch-card", app)

        card.tap()
        XCTAssertTrue(element("code.batch", in: app).waitForExistence(timeout: 5), "The card opens the batch chat.")
        for index in 0..<3 {
            XCTAssertTrue(app.buttons["code.batch.member.\(index)"].waitForExistence(timeout: 5))
        }
        save("14-batch-chat", app)

        let batchField = app.textViews["code.batch.field"]
        XCTAssertTrue(batchField.waitForExistence(timeout: 3))
        batchField.tap()
        batchField.typeText("#")
        XCTAssertTrue(element("code.batch.mentions", in: app).waitForExistence(timeout: 3), "# opens the list.")
        XCTAssertTrue(element("code.batch.mentions.row.session.0", in: app).exists)
        XCTAssertTrue(element("code.batch.mentions.row.pr.138", in: app).exists, "Open pull requests list too.")
        save("15-hash", app)
        element("code.batch.mentions.row.session.0", in: app).tap()
        XCTAssertTrue((batchField.value as? String)?.hasPrefix("#Widget tap ") == true)
        batchField.typeText("use the shared host check")
        XCTAssertTrue(element("code.batch.goes", in: app).waitForExistence(timeout: 3), "It says where it goes.")
        XCTAssertFalse(element("code.batch.mentions", in: app).exists, "Typing on after a pick closes the list.")
        XCTAssertEqual(app.buttons["code.batch.target"].label, "Sends to one session")
        save("16-mention", app)
        app.buttons["code.batch.send"].tap()

        let sent = element("code.batch.sent", in: app)
        XCTAssertTrue(sent.waitForExistence(timeout: 5), "The message shows in the batch chat.")
        XCTAssertTrue(app.staticTexts["To Widget tap"].waitForExistence(timeout: 3) || app.buttons["To Widget tap"].exists
                      || app.otherElements["To Widget tap"].exists, "Only the mentioned session got it.")
        save("17-sent", app)
    }

    /// Dev Factory on the demo data: the project's ⋯ on Work opens it; the sample start shows one card
    /// per project, and you approve one project's changes there; a template makes a new recipe, and
    /// Run starts it on the projects you pick.
    @MainActor
    func testDevFactoryRecipesRunsAndSignOff() throws {
        let app = launch()
        pickProject("bighelp", in: app)
        // A coding send opens the project's Work, whose ⋯ has Dev Factory.
        send("Fix the widget tap when the host is asleep", in: app)
        let more = app.buttons["work.project.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let menuRow = app.buttons["work.project.dev-factory"]
        XCTAssertTrue(menuRow.waitForExistence(timeout: 5), "The project's ⋯ lists Dev Factory.")
        menuRow.tap()
        XCTAssertTrue(element("devfactory.home", in: app).waitForExistence(timeout: 8))
        let group = app.buttons["devfactory.group-row"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8), "The sample start runs now.")
        save("18-factory-home", app)

        group.tap()
        XCTAssertTrue(element("devfactory.group", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("devfactory.run.bighelp-plugin", in: app).waitForExistence(timeout: 8))
        let approve = app.buttons["devfactory.approve"].firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 8), "A run waiting on its changes offers Approve.")
        XCTAssertTrue(app.buttons["devfactory.retry"].firstMatch.exists, "Failing tests offer Try again.")
        save("19-factory-run", app)
        approve.tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 10), "Approving moves the run on.")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let template = app.buttons["devfactory.template.fix-test-pr"]
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        template.tap()
        let project = app.switches["devfactory.new.project.bighelp"]
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        // A form row's switch flips where it draws, at the trailing edge.
        project.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(project.value as? String, "1")
        save("20-new-recipe", app)
        app.buttons["devfactory.new.create"].tap()
        XCTAssertTrue(element("devfactory.recipe", in: app).waitForExistence(timeout: 8), "Create opens the recipe.")
        save("21-recipe", app)

        app.buttons["devfactory.recipe.run"].tap()
        let task = element("devfactory.run-sheet.task", in: app)
        XCTAssertTrue(task.waitForExistence(timeout: 5))
        task.tap()
        task.typeText("Fix the widget tap")
        app.buttons["devfactory.run-sheet.start"].tap()
        XCTAssertTrue(element("devfactory.group", in: app).waitForExistence(timeout: 8), "Run opens its start.")
        XCTAssertTrue(element("devfactory.run.bighelp", in: app).waitForExistence(timeout: 8))
        save("22-new-run", app)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_CODE_MODE_APPEARANCE"] ?? "dark"
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    /// New chat with the demo's default bot, then a project from its chip: the choices row grows the rest.
    @MainActor
    private func pickProject(_ id: String, in app: XCUIApplication) {
        startNewChat(with: "finance", in: app)
        let chip = app.buttons["new-chat.chip.project"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "One bot picked: the choices row shows")
        XCTAssertEqual(chip.label, "Project: none")
        chip.tap()
        let project = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       "new-chat.project.\(id)", id)).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.tap()
        XCTAssertEqual(chip.label, "Project: \(id)")
        XCTAssertTrue(app.buttons["new-chat.chip.placement"].waitForExistence(timeout: 3))
    }

    /// A menu item reports its title (and subtitle) instead of its identifier, so look for both.
    @MainActor
    private func menuItem(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@", identifier, title)).firstMatch
    }

    /// One of the last chips of the choices row (the mode, Stage), scrolled into view: the choices
    /// are one row that scrolls sideways, and its last chips start past its right edge. The row is
    /// always dragged left once, along the chips' own line: `isHittable` says yes for a chip that is
    /// only partly in view, and the tap then lands beside it. The row stops at its end, so a chip
    /// that was in view stays there.
    @MainActor
    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let chip = app.buttons[identifier]
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "\(identifier) is in the choices row")
        let rail = element("new-chat.choices", in: app)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for attempt in 0..<3 {
            let bounds = rail.frame
            if attempt > 0, chip.frame.minX >= bounds.minX, chip.frame.maxX <= bounds.maxX { break }
            // The staged jobs sit over the chips in the same container, so its middle isn't the row.
            let line = chip.frame.midY
            origin.withOffset(CGVector(dx: bounds.maxX - 24, dy: line))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: bounds.minX + 24, dy: line)))
        }
        return chip
    }

    @MainActor
    private func stage(_ message: String, in app: XCUIApplication) {
        let field = app.textViews["chat.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(message)
        reveal("new-chat.chip.stage", in: app).tap()
    }

    @MainActor
    private func send(_ message: String, in app: XCUIApplication) {
        let field = app.textViews["chat.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(message)
        app.buttons["chat.send"].tap()
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
