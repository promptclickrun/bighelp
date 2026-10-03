import XCTest

/// Tool folders in plain words on demo data (`-test-tool-folders`): a live
/// folder shimmering with what the agent is doing and listing its calls, a
/// finished folder saying what it did, a finished turn folded into "Worked
/// for 2m 14s · 7 steps" with its answer below, and a call's output made
/// readable. Set BIGHELP_TOOL_FOLDERS_EVIDENCE (TEST_RUNNER_…) to a folder to
/// save the screenshots.
final class ChatToolFoldersUITests: BighelpUITestCase {
    @MainActor
    func testToolFoldersSayWhatTheAgentIsDoingAndDid() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))

            // The live folder streams the current call and lists the calls so far.
            let live = trail(in: app, labelPrefix: "Checking GitHub…")
            XCTAssertTrue(live.waitForExistence(timeout: 10))
            reveal(live, in: timeline)
            XCTAssertTrue(live.label.contains("2 steps"), live.label)
            XCTAssertEqual(live.value as? String, "Expanded")
            let listed = app.buttons["chat.activity.folders-t9"]
            XCTAssertTrue(listed.waitForExistence(timeout: 5))
            XCTAssertTrue(listed.label.hasPrefix("Checked GitHub"), listed.label)
            XCTAssertTrue(app.buttons["chat.activity.folders-t10"].label.hasPrefix("Checking GitHub…"))

            // The folder before the note is finished: it says what it did.
            let finished = trail(in: app, labelPrefix: "Checked your calendars")
            XCTAssertTrue(finished.exists)
            XCTAssertEqual(finished.value as? String, "Collapsed")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Done")).firstMatch.exists)
            save("tool-folders-live-\(appearance)", app)

            // The finished turn folds into its real time and steps; the answer stays out.
            let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked for 2m 14s")).firstMatch
            reveal(fold, in: timeline)
            XCTAssertTrue(fold.label.contains("7 steps"), fold.label)
            XCTAssertEqual(fold.value as? String, "Collapsed")
            let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "all 42 tests pass")).firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 5))
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Next I'm cloning"))
                .firstMatch.exists, "Narration sits inside the fold")
            place(fold, at: 0.3, in: timeline)
            save("tool-folders-turn-folded-\(appearance)", app)

            // Unfolded: the folders and narration as they were.
            fold.tap()
            XCTAssertEqual(fold.value as? String, "Expanded")
            let research = trail(in: app, labelPrefix: "Searched the web, read docs.example.com")
            XCTAssertTrue(research.waitForExistence(timeout: 5))
            let work = trail(in: app, labelPrefix: "Cloned weather-app, installed packages, ran tests")
            XCTAssertTrue(work.exists, "Expected the second folder's summary")
            XCTAssertTrue(work.label.contains("4 steps"), work.label)
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Next I'm cloning"))
                .firstMatch.waitForExistence(timeout: 5))
            reveal(fold, in: timeline)
            place(fold, at: 0.2, in: timeline)
            save("tool-folders-turn-unfolded-\(appearance)", app)

            // A call's output reads as facts and real lines, not escaped JSON.
            reveal(work, in: timeline, towardOlder: false)
            work.tap()
            let tests = app.buttons["chat.activity.folders-t5"]
            XCTAssertTrue(tests.waitForExistence(timeout: 5))
            XCTAssertTrue(tests.label.hasPrefix("Ran tests"), tests.label)
            reveal(tests, in: timeline, towardOlder: false)
            tests.tap()
            XCTAssertEqual(tests.value as? String, "Expanded")
            let exitCode = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Exit code")).firstMatch
            XCTAssertTrue(exitCode.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\\n")).firstMatch.exists)
            place(tests, at: 0.15, in: timeline)
            save("tool-folders-readable-output-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-tool-folders", "-loopdy.chat.foldCompletedTurns", "YES",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func trail(in app: XCUIApplication, labelPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                         "chat.work-trail.", labelPrefix)).firstMatch
    }

    /// Drags the timeline so the element's top sits at `fraction` of its
    /// height, below the glass header, for a screenshot that shows it.
    @MainActor
    private func place(_ element: XCUIElement, at fraction: CGFloat, in timeline: XCUIElement) {
        for _ in 0..<4 {
            guard element.exists else { return }
            let delta = element.frame.minY - (timeline.frame.minY + timeline.frame.height * fraction)
            guard abs(delta) > 40 else { return }
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let distance = max(-timeline.frame.height * 0.4, min(timeline.frame.height * 0.4, delta))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.4)
        }
    }

    /// Scrolls toward the element: older content is above, unfolded rows below.
    @MainActor
    private func reveal(_ element: XCUIElement, in timeline: XCUIElement, towardOlder: Bool = true) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            if element.exists, element.frame.minY > timeline.frame.midY {
                timeline.swipeUp(velocity: .slow)
            } else if element.exists || towardOlder {
                timeline.swipeDown(velocity: .slow)
            } else {
                timeline.swipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_TOOL_FOLDERS_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
