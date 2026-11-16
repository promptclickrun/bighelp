import XCTest

/// Kanban, Workflows and Usage left on screen through a reconnect, against a real, isolated Hermes host
/// with the bighelp plugin (Scripts/HostSignInMatrixProbe.py --modes reconnect --plugin …), with no demo
/// data. The shell's root setup waits while one of these pages covers the root, and a Today board once
/// kept the closed connection that way (#987). Each test opens a page, makes a change, leaves the app
/// until its connection closes, comes back with the page still on screen, and makes a change again
/// (#1042). Skipped without the probe.
final class ReconnectedPagesHostUITests: BighelpUITestCase {
    @MainActor
    func testKanbanTakesANewTaskAfterAReconnect() throws {
        let app = try start()
        try openWorkDoor("tasks", in: app)
        XCTAssertTrue(element("kanban.screen", app).waitForExistence(timeout: 20), "Kanban opens")
        try addTask("Water the tomatoes", in: app)
        save("reconnect-kanban-1-before", app)

        leaveUntilTheConnectionCloses(app)
        XCTAssertTrue(element("kanban.screen", app).waitForExistence(timeout: 10), "Kanban is still on screen")
        try addTask("Order new seeds", in: app)
        XCTAssertTrue(card("Water the tomatoes", app).exists, "The task from before the reconnect stays")
        save("reconnect-kanban-2-after", app)
    }

    @MainActor
    func testWorkflowsTakesANewWorkflowAfterAReconnect() throws {
        let app = try start()
        try openWorkDoor("workflows", in: app)
        XCTAssertTrue(element("workflows.home", app).waitForExistence(timeout: 20), "Workflows opens")
        try addWorkflow("Morning notes", in: app)
        save("reconnect-workflows-1-before", app)

        leaveUntilTheConnectionCloses(app)
        XCTAssertTrue(element("workflows.home", app).waitForExistence(timeout: 10), "Workflows is still on screen")
        try addWorkflow("Evening notes", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Morning notes")).firstMatch
            .waitForExistence(timeout: 15), "The workflow from before the reconnect stays")
        save("reconnect-workflows-2-after", app)
    }

    /// Usage opened by its link with Bighelp closed, as a tap on the Usage widget opens it. The page is
    /// on screen before the sign-in is known. It said "Connect to a computer to see usage" until you
    /// left it, because only the root set its stores up, and the root's tasks wait under a page.
    /// Then the page stays on screen through a reconnect and reads again.
    @MainActor
    func testUsageOpenedByItsLinkLoadsAndReadsAgainAfterAReconnect() throws {
        let app = try start()
        // `open` starts the app again with the link, so this is a cold start.
        app.open(try XCTUnwrap(URL(string: "loopdy://usage")))
        XCTAssertTrue(element("usage", app).waitForExistence(timeout: 30), "Usage opens")
        try expectUsageLoaded(in: app, "opened by its link")
        save("reconnect-usage-1-link", app)

        leaveUntilTheConnectionCloses(app)
        XCTAssertTrue(element("usage", app).waitForExistence(timeout: 10), "Usage is still on screen")
        let refresh = app.buttons["usage.refresh"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        refresh.tap()
        try expectUsageLoaded(in: app, "after the reconnect")
        save("reconnect-usage-2-after", app)
    }

    // MARK: Steps

    @MainActor private func start() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes reconnect")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "reconnect" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        XCTAssertTrue(app.buttons["home.new-chat"].firstMatch.waitForExistence(timeout: 30), "The home opens")
        return app
    }

    /// Past the 25-second grace the app closes its connection; coming back makes a new one.
    @MainActor private func leaveUntilTheConnectionCloses(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(45)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor private func openWorkDoor(_ kind: String, in app: XCUIApplication) throws {
        let work = app.buttons["home.tab.work"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()
        let door = app.buttons["work.door.\(kind)"].firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 45), "Work has the \(kind) door on this computer")
        door.tap()
    }

    @MainActor private func addTask(_ title: String, in app: XCUIApplication) throws {
        let new = app.buttons["kanban.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 20), "Kanban has its New button")
        new.tap()
        let field = app.textFields["kanban.new.title"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(title)
        let add = app.buttons["kanban.new.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        if !card(title, app).waitForExistence(timeout: 25) {
            save("reconnect-kanban-refused-\(title.prefix(5))", app)
            XCTFail("The computer took the task “\(title)”: \(notice(in: app))")
        }
    }

    @MainActor private func addWorkflow(_ name: String, in app: XCUIApplication) throws {
        let scratch = app.buttons["workflows.template.scratch"].firstMatch
        for _ in 0..<6 where !(scratch.exists && scratch.isHittable) { app.swipeUp() }
        XCTAssertTrue(scratch.waitForExistence(timeout: 20), "Workflows offers a workflow from scratch")
        scratch.tap()
        let prompt = app.alerts["New workflow"]
        let field = prompt.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(name)
        prompt.buttons["Create"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier IN %@", ["workflows.flow.inputs", "workflows.canvas.node.inputs"])).firstMatch
        if !editor.waitForExistence(timeout: 25) {
            save("reconnect-workflows-refused-\(name.prefix(5))", app)
            XCTFail("The computer made the workflow “\(name)”: \(notice(in: app))")
            return
        }
        // Back to the Workflows page, which stays on screen for the next step.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element("workflows.home", app).waitForExistence(timeout: 10))
        for _ in 0..<4 { app.swipeDown() }
    }

    @MainActor private func expectUsageLoaded(in app: XCUIApplication, _ when: String) throws {
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
                                  "couldn't be loaded", "isn't connected", "Connect to a computer")).firstMatch
        let hero = element("usage.hero", app)
        let deadline = Date().addingTimeInterval(45)
        // A page with no computer to read says so at once and stays that way, so give it the whole wait.
        while Date() < deadline, !hero.exists { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(failed.exists, "Usage loads \(when): \(failed.exists ? failed.label : "")")
        XCTAssertTrue(hero.exists, "Hermes' own usage shows \(when)")
    }

    @MainActor private func card(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "kanban.card.", title)).firstMatch
    }

    /// What the page says went wrong, for the failure's message.
    @MainActor private func notice(in app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label)
        return texts.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    @MainActor private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
