import XCTest

/// Demo data: a run's stage opens what it used, made and decided; a workflow's trigger goes from
/// Manual to a schedule; Settings › Notifications has the workflow switches; the scheduled task
/// editor keeps its picker. BIGHELP_WORKFLOWS_EVIDENCE (TEST_RUNNER_…) saves screenshots;
/// BIGHELP_WORKFLOWS_APPEARANCE picks light or dark.
final class WorkflowsStagesAndTriggersUITests: BighelpUITestCase {
    @MainActor
    func testARunStageShowsWhatItUsedMadeAndDecided() throws {
        let app = launch()
        openWorkflows(app)
        app.buttons["workflows.waiting.run-14"].tap()
        XCTAssertTrue(element("workflows.run", app).waitForExistence(timeout: 8))

        let decide = app.buttons["workflows.run.stage.decide"]
        scrollTo(decide, in: app)
        decide.tap()
        XCTAssertTrue(element("workflows.run.stage-sheet", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.run.stage.decided-by", app).waitForExistence(timeout: 5),
                      "A decision says who made it")
        save("30-stage-decision", app)
        app.buttons["Done"].firstMatch.tap()

        let draft = app.buttons["workflows.run.stage.draft"]
        scrollTo(draft, in: app)
        draft.tap()
        let input = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workflows.run.stage.input.")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "It lists what it used")
        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workflows.run.stage.file.draft.")).firstMatch
        // The list builds rows as they come on screen.
        for _ in 0..<4 where !(file.exists && file.isHittable) {
            element("workflows.run.stage-sheet", app).swipeUp()
        }
        XCTAssertTrue(file.waitForExistence(timeout: 5), "It lists the file it made")
        save("31-stage-agent", app)
        file.tap()
        XCTAssertTrue(element("workflows.document", app).waitForExistence(timeout: 8), "The file opens")
        save("32-stage-file", app)
    }

    @MainActor
    func testAScheduleReplacesManualAndShowsOnTheWorkflow() throws {
        let app = launch()
        openWorkflows(app)
        app.buttons["workflows.workflow.wf-research"].tap()
        let card = app.buttons["workflows.trigger.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        XCTAssertTrue(card.label.contains("Manual"), card.label)
        card.tap()
        XCTAssertTrue(element("workflows.trigger", app).waitForExistence(timeout: 5))
        app.buttons["Scheduled"].firstMatch.tap()
        XCTAssertTrue(element("workflows.trigger.summary", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.trigger.needs-inputs", app).exists, "It says why Save waits")
        XCTAssertFalse(app.buttons["workflows.trigger.save"].isEnabled)
        let topic = app.textFields["workflows.trigger.topic"]
        for _ in 0..<4 where !topic.isHittable { app.swipeUp() }
        topic.tap()
        topic.typeText("Made-up topic")
        save("33-trigger-scheduled", app)
        app.buttons["workflows.trigger.save"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let scheduled = NSPredicate(format: "label CONTAINS %@", "weekday")
        expectation(for: scheduled, evaluatedWith: card)
        waitForExpectations(timeout: 8)
        save("34-trigger-card", app)
    }

    @MainActor
    func testNotificationsHaveWorkflowSwitches() throws {
        let app = launch()
        openRootTab("tab.profile", in: app)
        settingsRow("settings.menu.notifications", in: app).tap()
        let needsYou = app.switches["settings.notifications.workflows.needsYou"].firstMatch
        for _ in 0..<8 where !(needsYou.exists && needsYou.isHittable) { app.swipeUp() }
        XCTAssertTrue(needsYou.exists)
        XCTAssertTrue(app.switches["settings.notifications.workflows.cancelled"].exists)
        save("35-notification-workflows", app)
    }

    /// The scheduled task editor's "When?" is the same picker the workflow trigger uses.
    @MainActor
    func testScheduledTaskEditorKeepsItsPicker() throws {
        let app = launch()
        openRootTab("tab.scheduled-tasks", in: app)
        let create = app.buttons["scheduled-tasks.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.textFields["scheduled-task.editor.name"].waitForExistence(timeout: 8))
        let frequency = element("scheduled-task.editor.frequency", app)
        for _ in 0..<4 where !(frequency.exists && frequency.isHittable) { app.swipeUp() }
        XCTAssertTrue(frequency.exists)
        app.buttons["Weekdays"].firstMatch.tap()
        XCTAssertTrue(element("scheduled-task.editor.weekday.monday", app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("scheduled-task.editor.summary", app).label.contains("weekday"),
                      element("scheduled-task.editor.summary", app).label)
        save("38-task-editor-picker", app)
    }

    // MARK: Helpers

    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_WORKFLOWS_APPEARANCE"] ?? "light" }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func openWorkflows(_ app: XCUIApplication) {
        openWorkDoor("workflows", in: app)
        XCTAssertTrue(app.buttons["workflows.waiting.run-14"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func element(_ identifier: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WORKFLOWS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder)
            .appendingPathComponent("\(name)-\(appearance).png"))
    }
}
