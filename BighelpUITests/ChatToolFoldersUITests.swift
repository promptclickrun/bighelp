import XCTest

/// Tool folders in plain words on demo data (`-test-tool-folders`): a live
/// folder shimmering with what the agent is doing and listing its calls, a
/// finished folder saying what it did, a finished turn folded into what it
/// did ("2m 14s · 7 steps" under it) with its answer below, the turn's
/// reasoning as a message of its own above the work, and an open tool call
/// as one readable block (#943). Set BIGHELP_TOOL_FOLDERS_EVIDENCE (TEST_RUNNER_…) to a folder to
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
            XCTAssertEqual(app.buttons["chat.activity.folders-t9"].value as? String, "Collapsed",
                           "A finished individual tool remains collapsed")

            // The folder before the note is finished: it says what it did.
            let finished = trail(in: app, labelPrefix: "Checked your calendars")
            XCTAssertTrue(finished.exists)
            XCTAssertEqual(finished.value as? String, "Expanded", "Full keeps every folder open")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Done")).firstMatch.exists)
            save("tool-folders-live-\(appearance)", app)

            // The finished turn folds into what it did, with its real time and steps; the answer stays out.
            let fold = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.completed-turn:"))
                .firstMatch
            reveal(fold, in: timeline)
            XCTAssertTrue(fold.label.hasPrefix("Searched the web"), fold.label)
            XCTAssertTrue(fold.label.hasSuffix("2m 14s, 7 steps"), fold.label)
            XCTAssertEqual(fold.value as? String, "Collapsed")

            // The turn's reasoning is one message above its work, open, with every thought in it.
            let reasoning = app.buttons["chat.reasoning:message:folders-q1"]
            XCTAssertTrue(reasoning.exists)
            XCTAssertEqual(reasoning.label, "Thought for 12s")
            XCTAssertEqual(reasoning.value as? String, "Expanded", "Keep thinking open is on by default")
            XCTAssertLessThan(reasoning.frame.minY, fold.frame.minY, "Above the work")
            let words = app.staticTexts["chat.reasoning:message:folders-q1.words"]
            XCTAssertTrue(words.label.contains("Finding the setup steps"), words.label)
            XCTAssertTrue(app.buttons["chat.reasoning:message:folders-q1.show-more"].exists, "Cut at six lines")
            let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "all 42 tests pass")).firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 5))
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Next I'm cloning"))
                .firstMatch.exists, "Narration sits inside the fold")
            place(fold, at: 0.3, in: timeline)
            save("tool-folders-turn-folded-\(appearance)", app)

            // Unfolded: its steps and narration as they were, with no second folder inside it.
            fold.tap()
            XCTAssertEqual(fold.value as? String, "Expanded")
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Next I'm cloning"))
                .firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(trail(in: app, labelPrefix: "Searched the web").exists, "No folder inside the opened turn")
            XCTAssertFalse(trail(in: app, labelPrefix: "Cloned weather-app").exists, "No folder inside the opened turn")
            reveal(fold, in: timeline)
            place(fold, at: 0.2, in: timeline)
            save("tool-folders-turn-unfolded-\(appearance)", app)

            // The opened turn holds only tool calls and notes: the thinking is in its message.
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Finding the setup"))
                .firstMatch.exists, "No thinking rows between the steps")

            // An open call is one block: what it asked for, then what came back, never JSON.
            let read = app.buttons["chat.activity.folders-t6"]
            reveal(read, in: timeline, towardOlder: false)
            XCTAssertTrue(read.label.hasPrefix("Read"), read.label)
            read.tap()
            XCTAssertEqual(read.value as? String, "Expanded")
            let ask = app.staticTexts["chat.activity.folders-t6.ask.line"]
            XCTAssertTrue(ask.waitForExistence(timeout: 5))
            XCTAssertEqual(ask.label, "weather-app/notes.md")
            XCTAssertEqual(app.staticTexts["chat.activity.folders-t6.answer.line"].label, "Total lines 3")
            let text = app.staticTexts["chat.activity.folders-t6.answer.text-0"]
            XCTAssertTrue(text.label.contains("# Notes\n- cache.test.ts is flaky"), text.label)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "\\n")).firstMatch.exists)
            XCTAssertTrue(app.buttons["chat.activity.folders-t6.copy"].exists)
            XCTAssertTrue(app.buttons["chat.activity.folders-t6.view-raw"].exists)
            XCTAssertFalse(app.staticTexts["Input"].exists || app.staticTexts["Result"].exists,
                           "No Summary, Input and Result boxes")
            place(read, at: 0.15, in: timeline)
            save("tool-folders-readable-output-\(appearance)", app)

            // Closing the reasoning leaves one line, and the reader's choice holds.
            reveal(reasoning, in: timeline)
            // Clear of the glass header, which would take the tap.
            place(reasoning, at: 0.3, in: timeline)
            reasoning.tap()
            XCTAssertEqual(reasoning.value as? String, "Collapsed")
            XCTAssertFalse(words.exists)
            save("tool-folders-reasoning-closed-\(appearance)", app)
            app.terminate()
        }
    }

    /// `-test-thinking-style`, in Card: a finished turn and one whose agent is still thinking.
    @MainActor
    func testReasoningIsItsOwnMessageAndFollowsItsSettings() throws {
        func launch(_ extra: [String] = [], appearance: String = "light") -> XCUIApplication {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-thinking-style", "-loopdy.chat.foldCompletedTurns", "YES",
                                   "-bighelp.chat.work-style", "card", "-loopdy.demo.appearance", appearance] + extra
            app.launch()
            XCTAssertTrue(app.tables["chat.timeline"].waitForExistence(timeout: 10))
            return app
        }
        let finishedID = "chat.reasoning:message:thinking-q1"
        let liveID = "chat.reasoning:message:thinking-q2"

        // The defaults: its own message, open. The running turn's says Reasoning… over its newest words.
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let live = app.buttons[liveID]
            XCTAssertTrue(live.waitForExistence(timeout: 10))
            XCTAssertEqual(live.label, "Reasoning…")
            XCTAssertEqual(live.value as? String, "Expanded")
            XCTAssertTrue(app.staticTexts["\(liveID).words"].label.contains("Filter card charges"))
            let block = app.descendants(matching: .any)["chat.live-work"].firstMatch
            if block.exists { XCTAssertLessThan(live.frame.minY, block.frame.minY, "Above the work") }
            save("reasoning-live-\(appearance)", app)
            app.terminate()
        }

        // Keep thinking open off: finished reasoning is one line; the running one still shows its words.
        var app = launch(["-\(Self.staysOpenKey)", "NO"])
        let timeline = app.tables["chat.timeline"]
        XCTAssertEqual(app.buttons[liveID].value as? String, "Expanded")
        let finished = app.buttons[finishedID]
        reveal(finished, in: timeline)
        XCTAssertEqual(finished.label, "Thought for 16s")
        XCTAssertEqual(finished.value as? String, "Collapsed")
        XCTAssertFalse(app.staticTexts["\(finishedID).words"].exists)
        place(finished, at: 0.3, in: timeline)
        save("reasoning-finished-closed-light", app)
        finished.tap()
        XCTAssertEqual(finished.value as? String, "Expanded", "The reader's choice wins over the setting")
        XCTAssertTrue(app.staticTexts["\(finishedID).words"].waitForExistence(timeout: 5))
        app.terminate()

        // In the steps: no message of its own.
        app = launch(["-\(Self.placementKey)", "steps"])
        XCTAssertFalse(app.buttons[liveID].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.reasoning:"))
            .firstMatch.exists)
        app.terminate()
    }

    private static let placementKey = "bighelp.chat.reasoning-placement"
    private static let staysOpenKey = "bighelp.chat.reasoning-stays-open"

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-tool-folders", "-loopdy.chat.foldCompletedTurns", "YES",
                               "-bighelp.chat.work-style", "full",
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
