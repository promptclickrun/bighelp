import XCTest

/// Workflows on demo data: a draft says it isn't live and has Publish, and a field's default
/// value can be set by hand and fills in the Run sheet. Set BIGHELP_WORKFLOW_PUBLISH_EVIDENCE
/// (TEST_RUNNER_…) to save screenshots.
final class WorkflowPublishUITests: BighelpUITestCase {
    @MainActor
    func testADraftSaysItIsntLiveAndHasPublish() throws {
        let app = launch()
        app.open(URL(string: "loopdy://workflows/wf-captions")!)
        let bar = app.descendants(matching: .any)["workflows.publish-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "A never-published workflow says it's a draft")
        XCTAssertTrue(app.buttons["workflows.publish"].exists)
        save("publish-1-draft", app)
    }

    @MainActor
    func testADefaultValueSavesThenPublishMakesItLive() throws {
        let app = launch()
        app.open(URL(string: "loopdy://workflows/wf-triage")!)
        let inputs = app.descendants(matching: .any)["workflows.flow.inputs"]
        XCTAssertTrue(inputs.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["workflows.publish-bar"].exists, "Published and up to date")
        inputs.tap()

        let field = app.textFields["workflows.input.repo.default"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Each field has a default value")
        field.tap()
        field.typeText("example/weather-app")
        save("publish-2-default-value", app)
        app.buttons["workflows.inputs.done"].tap()

        let bar = app.descendants(matching: .any)["workflows.publish-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "The change isn't live until it's published")
        save("publish-3-changes-not-published", app)
        let publish = app.buttons["workflows.publish"]
        XCTAssertTrue(publish.isEnabled)
        publish.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: bar)], timeout: 10),
                       .completed, "Published: the bar goes away")
        save("publish-4-published", app)

        let run = app.buttons["workflows.flow.run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        let value = app.textFields["workflows.run-sheet.repo"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(value.value as? String, "example/weather-app", "The run starts with the default filled in")
        save("publish-5-run-sheet", app)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"]))
            .firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WORKFLOW_PUBLISH_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
