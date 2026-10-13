import XCTest

/// Bighelp IDE against a real Hermes host: a send makes a worktree and a session on
/// the chosen model, the agent's change shows in Changes, and Ship commits it.
/// Needs a project whose main folder is a throwaway git repository with no remote.
/// Set (as TEST_RUNNER_…):
/// - BIGHELP_CODE_HOST: the host's address, e.g. 127.0.0.1:9121 (an open host)
/// - BIGHELP_CODE_PROJECT: the Hermes project ID
/// - BIGHELP_CODE_MODEL: words in the model's name, e.g. "Luna"
/// - BIGHELP_CODE_PROVIDER: the provider to take it from, e.g. openai-codex (the ChatGPT subscription)
/// - BIGHELP_CODE_MODE_EVIDENCE: a folder for screenshots (optional)
final class CodeModeHostUITests: BighelpUITestCase {
    @MainActor
    func testASendBecomesAWorktreeSessionWhoseChangeShips() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_CODE_HOST"], let project = environment["BIGHELP_CODE_PROJECT"] else {
            throw XCTSkip("Set BIGHELP_CODE_HOST and BIGHELP_CODE_PROJECT")
        }
        let app = makeApp()
        app.launchArguments = ["-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code"]
        app.launch()
        try onboardOpenHost(app, address: host)
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 30), "Bighelp IDE is the home.")

        app.buttons["code.chip.project"].tap()
        let probe = app.buttons["code.project.\(project)"]
        if !probe.waitForExistence(timeout: 30) { save("host-projects-missing", app) }
        XCTAssertTrue(probe.exists, "The host's project is listed.")
        probe.tap()

        if let model = environment["BIGHELP_CODE_MODEL"] {
            app.buttons["code.composer.agent"].tap()
            app.buttons["code.runtime.model"].tap()
            // Lists build only the rows on screen: search narrows it to the model.
            let search = app.searchFields["code.runtime.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText(model)
            save("host-0-models", app)
            let provider = environment["BIGHELP_CODE_PROVIDER"].map { "\($0)." } ?? ""
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                                       "code.runtime.model.\(provider)", model)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(model) is offered.")
            row.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.buttons["code.runtime.reasoning"].tap()
            app.buttons["Low"].firstMatch.tap()
            save("host-1-model", app)
            app.buttons["Done"].firstMatch.tap()
        }

        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "code.session."))
        let earlier = Set(cards.allElementsBoundByIndex.map(\.identifier))
        let field = element("code.composer.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Create a file named HELLO.md containing exactly one line: hello from Bighelp IDE. "
                       + "Do not change any other file and do not commit.")
        app.buttons["code.composer.send"].tap()

        // This send's card: the one that wasn't there before.
        var newID: String?
        let appeared = Date().addingTimeInterval(120)
        while newID == nil, Date() < appeared {
            newID = cards.allElementsBoundByIndex.map(\.identifier).first { !earlier.contains($0) }
            if newID == nil { sleep(2) }
        }
        // Real session IDs run past XCUITest's 128-character subscript limit.
        let card = app.buttons.matching(NSPredicate(format: "identifier == %@",
                                                    try XCTUnwrap(newID, "The send became a session card."))).firstMatch
        save("host-2-running", app)
        let deadline = Date().addingTimeInterval(300)
        while !card.label.contains("Ready"), Date() < deadline {
            XCTAssertFalse(card.label.contains("Approve") || card.label.contains("Answer"), "The agent asked for help.")
            sleep(3)
        }
        XCTAssertTrue(card.label.contains("Ready"), "The session finished: \(card.label)")
        save("host-3-ready", app)

        card.press(forDuration: 1.2)
        app.buttons["Changes"].firstMatch.tap()
        let file = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                    "code.changes.file", "HELLO.md")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 30), "The agent's file shows in Changes.")
        save("host-4-changes", app)

        app.buttons["code.changes.ship"].tap()
        XCTAssertTrue(element("code.ship", in: app).waitForExistence(timeout: 10))
        // The probe repository has no remote: commit only.
        for toggle in ["code.ship.push", "code.ship.pull-request"] {
            let control = app.switches[toggle]
            // The switch sits at the row's trailing edge.
            if control.value as? String == "1" { control.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        }
        save("host-5-ship", app)
        app.buttons["code.ship.go"].tap()
        XCTAssertTrue(element("code.ship", in: app).waitForNonExistence(timeout: 60), "Ship finished.")
        let committed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "committed")).firstMatch
        XCTAssertTrue(committed.waitForExistence(timeout: 20), "Changes says it's committed.")
        save("host-6-committed", app)
    }

    /// Plan mode writes a Markdown plan that opens rendered from the chat.
    @MainActor
    func testPlanModeWritesAPlanThatOpensRendered() throws {
        let app = try openProbe()
        choose("Plan", in: app)
        let plan = try sendAndWait("Plan how to add a CONTRIBUTING.md file with one line of text. Keep the plan short.",
                                   in: app)
        save("host-7-plan-ready", app)
        plan.tap()
        XCTAssertTrue(element("chat.composer-shell", in: app).waitForExistence(timeout: 15))
        // Hermes saves plans under .hermes/plans/; the request names a file too, so match the plan's folder.
        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", "plans/")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 30), "The reply names the plan's file as a link.")
        link.tap()
        XCTAssertTrue(element("markdown-file.rendered", in: app).waitForExistence(timeout: 20),
                      "The plan Hermes wrote opens rendered.")
        save("host-8-plan-open", app)
    }

    /// YOLO starts a session with Hermes' YOLO on (the app checks Hermes' answer, so a refusal fails the send).
    @MainActor
    func testYOLOModeStartsTheSessionWithYOLOOn() throws {
        let app = try openProbe()
        choose("YOLO", in: app)
        let yolo = try sendAndWait("Create a file named YOLO.md containing exactly one line: yolo. Do not commit.", in: app)
        XCTAssertTrue(yolo.label.contains("YOLO"), "The card says YOLO: \(yolo.label)")
        XCTAssertFalse(yolo.label.contains("didn't turn on YOLO"))
        save("host-9-yolo-ready", app)
    }

    /// Signs in to the host, picks the probe project and the model, on the IDE home.
    @MainActor
    private func openProbe() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["BIGHELP_CODE_HOST"], let project = environment["BIGHELP_CODE_PROJECT"] else {
            throw XCTSkip("Set BIGHELP_CODE_HOST and BIGHELP_CODE_PROJECT")
        }
        let app = makeApp()
        app.launchArguments = ["-bighelp.settings.code-mode", "YES", "-bighelp.settings.code-mode.open-in", "code"]
        app.launch()
        try onboardOpenHost(app, address: host)
        XCTAssertTrue(element("code.screen", in: app).waitForExistence(timeout: 30), "Bighelp IDE is the home.")
        app.buttons["code.chip.project"].tap()
        // By its ID, or its name (a project made with the CLI has an ID of the host's own).
        let probe = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR (identifier BEGINSWITH %@ AND label CONTAINS[c] %@)",
            "code.project.\(project)", "code.project.", project)).firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "The host's project is listed.")
        probe.tap()
        if let model = environment["BIGHELP_CODE_MODEL"] { pick(model, provider: environment["BIGHELP_CODE_PROVIDER"], in: app) }
        return app
    }

    @MainActor
    private func pick(_ model: String, provider: String?, in app: XCUIApplication) {
        app.buttons["code.composer.agent"].tap()
        app.buttons["code.runtime.model"].tap()
        let search = app.searchFields["code.runtime.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(model)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                                   "code.runtime.model.\(provider.map { "\($0)." } ?? "")", model)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(model) is offered.")
        row.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["code.runtime.reasoning"].tap()
        app.buttons["Low"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    private func choose(_ mode: String, in app: XCUIApplication) {
        app.buttons["code.composer.mode"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", mode)).firstMatch.tap()
        XCTAssertEqual(app.buttons["code.composer.mode"].label, "Mode: \(mode)")
    }

    /// Sends `message` and returns its new card once the session is Ready.
    @MainActor
    private func sendAndWait(_ message: String, in app: XCUIApplication) throws -> XCUIElement {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "code.session."))
        let earlier = Set(cards.allElementsBoundByIndex.map(\.identifier))
        let field = element("code.composer.field", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(message)
        app.buttons["code.composer.send"].tap()
        var newID: String?
        let appeared = Date().addingTimeInterval(120)
        while newID == nil, Date() < appeared {
            newID = cards.allElementsBoundByIndex.map(\.identifier).first { !earlier.contains($0) }
            if newID == nil { sleep(2) }
        }
        let card = app.buttons.matching(NSPredicate(format: "identifier == %@",
                                                    try XCTUnwrap(newID, "The send became a session card."))).firstMatch
        let deadline = Date().addingTimeInterval(300)
        while !card.label.contains("Ready"), Date() < deadline { sleep(3) }
        XCTAssertTrue(card.label.contains("Ready"), "The session finished: \(card.label)")
        return card
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
