import XCTest

/// Demo fixtures only (`-test-subagent-canvas`): a turn with two helpers whose
/// Hermes-shaped events and saved sessions run through the real native chat.
final class SubagentCanvasUITests: BighelpUITestCase {
    @MainActor
    func testWatchingASubagentShowsItsStepsLiveAndHowItEnded() throws {
        try watch(appearance: "light")
    }

    @MainActor
    func testWatchingASubagentInDarkMode() throws {
        try watch(appearance: "dark")
    }

    @MainActor
    private func watch(appearance: String) throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                "-test-subagent-canvas", "-loopdy.demo.appearance", appearance]
        app.launch()

        // The rail says Subagents, and counts the ones working.
        let rail = app.buttons["chat.session-status.subagents"]
        XCTAssertTrue(rail.waitForExistence(timeout: 20), "Running helpers must surface the Subagents rail.")
        XCTAssertTrue(rail.staticTexts["Subagents"].exists, "The rail is called Subagents, not Agents.")
        XCTAssertEqual(rail.label, "2 active subagents")
        capture(app, "\(appearance)-1-rail")

        rail.tap()
        let ryokan = app.buttons["subagent.native.roster.sa-ryokan"]
        XCTAssertTrue(ryokan.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["subagent.native.roster.sa-trains"].exists)
        XCTAssertTrue(ryokan.label.contains("Find a quiet ryokan"), ryokan.label)
        XCTAssertTrue(ryokan.label.contains("Working"), ryokan.label)
        capture(app, "\(appearance)-2-roster")

        ryokan.tap()
        let canvas = app.descendants(matching: .any)["subagent.canvas.sa-ryokan"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "Tapping a subagent opens its canvas.")
        // Checked first: the fixture's next step lands a few seconds after the canvas opens.
        let status = app.staticTexts["subagent.canvas.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.hasPrefix("Working"), status.label)
        capture(app, "\(appearance)-3-canvas-working")
        let goal = app.descendants(matching: .any)["subagent.canvas.goal"]
        XCTAssertTrue(goal.waitForExistence(timeout: 3))
        XCTAssertTrue(goal.label.contains("Kyoto Station"), goal.label)

        // The saved record fills in the real file name the live stream couldn't give.
        XCTAssertTrue(element(app, labelContaining: "kyoto-trip.md").waitForExistence(timeout: 10),
                      "The helper's saved record names the file it read.")

        // It keeps updating while open: a later step lands, then the end.
        XCTAssertTrue(element(app, labelContaining: "ryokan-kanra.example").waitForExistence(timeout: 15)
                      || element(app, labelContaining: "web page").exists,
                      "A step that happens while the canvas is open shows up in it.")
        let done = NSPredicate(format: "label BEGINSWITH %@", "Done")
        expectation(for: done, evaluatedWith: status)
        waitForExpectations(timeout: 40)
        XCTAssertTrue(status.label.contains("1m 24s"), status.label)
        let result = app.descendants(matching: .any)["subagent.canvas.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, labelContaining: "ryokan-pick.md").exists)
        XCTAssertTrue(element(app, labelContaining: "Hotel Kanra is the best fit").waitForExistence(timeout: 10),
                      "The helper's reply shows once it finishes.")
        app.swipeUp()
        capture(app, "\(appearance)-4-canvas-done")

        // Back in the list, the finished helper stays to be read, with the other still working.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(ryokan.waitForExistence(timeout: 5))
        XCTAssertTrue(ryokan.label.contains("Done"), ryokan.label)
        XCTAssertTrue(app.buttons["subagent.native.roster.sa-trains"].label.contains("Working"))
        capture(app, "\(appearance)-5-roster-after")
    }

    @MainActor
    func testSteeringAndStoppingAHelperWhileItWorks() throws {
        try steerAndStop(appearance: "light")
    }

    @MainActor
    func testSteeringAndStoppingAHelperInDarkMode() throws {
        try steerAndStop(appearance: "dark")
    }

    /// The trains helper keeps working in the demo: send it a message, then stop it.
    @MainActor
    private func steerAndStop(appearance: String) throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                "-test-subagent-canvas", "-loopdy.demo.appearance", appearance]
        app.launch()
        let rail = app.buttons["chat.session-status.subagents"]
        XCTAssertTrue(rail.waitForExistence(timeout: 20))
        rail.tap()
        let trains = app.buttons["subagent.native.roster.sa-trains"]
        XCTAssertTrue(trains.waitForExistence(timeout: 5))
        trains.tap()

        let field = app.textFields["subagent.canvas.steer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "A helper that takes messages offers the message box.")
        let stop = app.buttons["subagent.canvas.stop"]
        XCTAssertTrue(stop.exists, "A running helper can be stopped.")
        capture(app, "\(appearance)-6-controls")

        field.tap()
        field.typeText("Prefer the JR line over the tram.")
        app.buttons["subagent.canvas.steer.send"].tap()
        let result = app.staticTexts["subagent.canvas.control-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "Sent. It reads your message before its next step.")
        XCTAssertTrue(["", "Tell it something"].contains(field.value as? String ?? ""), "A sent message leaves the box.")
        capture(app, "\(appearance)-7-steered")

        stop.tap()
        let status = app.staticTexts["subagent.canvas.status"]
        let stopped = NSPredicate(format: "label == %@", "Stopped")
        expectation(for: stopped, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["subagent.canvas.stop"].exists, "A stopped helper has no controls.")
        capture(app, "\(appearance)-8-stopped")
    }

    @MainActor
    private func element(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "subagent-canvas-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_SUBAGENT_SHOTS"], !directory.isEmpty {
            try? shot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("subagent-canvas-\(name).png"))
        }
    }
}
