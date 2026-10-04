import XCTest

/// ☰ › Workflows on demo data: home, the run waiting for you, its sign-off and Approve.
/// BIGHELP_WORKFLOWS_EVIDENCE (TEST_RUNNER_…) saves each screen as a PNG; run once in
/// light and once in dark appearance for both sets.
final class WorkflowsUITests: BighelpUITestCase {
    @MainActor
    func testMenuOpensWorkflowsAndApprovingTheWaitingRunFinishesIt() throws {
        let app = launch()
        openWorkflows(app)
        save("01-home", app)

        let waiting = app.buttons["workflows.waiting.run-14"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "The run waiting for you leads the home")
        waiting.tap()
        XCTAssertTrue(element("workflows.run", app).waitForExistence(timeout: 8))
        let review = app.buttons["workflows.run.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5), "A waiting run offers its sign-off")
        save("02-run-waiting", app)
        review.tap()

        XCTAssertTrue(element("workflows.signoff", app).waitForExistence(timeout: 8))
        let approve = app.buttons["workflows.signoff.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        XCTAssertTrue(element("workflows.signoff.fingerprint", app).exists, "It says which exact file is approved")
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: approve)
        waitForExpectations(timeout: 8)
        save("03-signoff", app)
        approve.tap()
        XCTAssertTrue(element("workflows.signoff.done", app).waitForExistence(timeout: 8), "Approved, and nothing published")
        save("04-approved", app)
    }

    /// Token counts are for Nerd Mode; the run's time and stages are always there.
    @MainActor
    func testTokenCountsAreNerdModeOnly() throws {
        for nerd in ["NO", "YES"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                   "-loopdy.settings.nerd-mode", nerd]
            app.launch()
            openWorkflows(app)
            let running = app.buttons["workflows.run.run-15"]
            XCTAssertTrue(running.waitForExistence(timeout: 5))
            running.tap()
            let line = element("workflows.run.line", app)
            XCTAssertTrue(line.waitForExistence(timeout: 8))
            let text = line.label
            XCTAssertTrue(text.contains("stages done"), text)
            XCTAssertEqual(text.contains("tokens"), nerd == "YES", text)
            XCTAssertEqual(element("workflows.run.nerd", app).exists, nerd == "YES")
            if nerd == "NO" { save("05-run-running", app) }
            app.terminate()
        }
    }

    /// Every other screen, for the screenshots: the flow, a stage, Run, a run that
    /// needs attention, and all runs.
    @MainActor
    func testScreensForEvidence() throws {
        let app = launch()
        openWorkflows(app)
        let workflow = app.buttons["workflows.workflow.wf-research"]
        XCTAssertTrue(workflow.waitForExistence(timeout: 5))
        workflow.tap()
        let draft = app.buttons["workflows.flow.stage.draft"]
        if draft.waitForExistence(timeout: 8) {
            save("06-flow", app)
            draft.tap()
            XCTAssertTrue(element("workflows.stage-editor", app).waitForExistence(timeout: 5))
            save("07-stage-editor", app)
            app.buttons["Cancel"].firstMatch.tap()
            let run = app.buttons["workflows.flow.run"]
            XCTAssertTrue(run.waitForExistence(timeout: 5))
            run.tap()
            XCTAssertTrue(app.buttons["workflows.run-sheet.run"].waitForExistence(timeout: 5))
            save("08-run-sheet", app)
            app.buttons["Cancel"].firstMatch.tap()
        } else {
            // Regular width: the canvas.
            XCTAssertTrue(element("workflows.canvas", app).waitForExistence(timeout: 8))
            save("06-canvas", app)
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let attention = app.buttons["workflows.run.run-12"]
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        attention.tap()
        XCTAssertTrue(element("workflows.run.problem", app).waitForExistence(timeout: 8))
        save("09-run-attention", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let allRuns = app.buttons["workflows.all-runs"].firstMatch
        XCTAssertTrue(allRuns.waitForExistence(timeout: 5))
        allRuns.tap()
        XCTAssertTrue(element("workflows.monitor", app).waitForExistence(timeout: 8))
        sleep(1)
        save("10-all-runs", app)
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func openWorkflows(_ app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let row = app.buttons["menu.workflows"]
        XCTAssertTrue(row.waitForExistence(timeout: 8), "☰ lists Workflows after Kanban on a host that has them")
        row.tap()
        XCTAssertTrue(element("workflows.home", app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["workflows.waiting.run-14"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WORKFLOWS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
