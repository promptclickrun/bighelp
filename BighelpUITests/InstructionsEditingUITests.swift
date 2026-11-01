import XCTest
import CoreFoundation

/// Editing an agent's instructions (#727) on demo data with a long SOUL (`-test-long-soul`, about
/// 6,000 characters): the box in Edit Agent, the full-screen editor its expand button opens, and
/// Bots mode's Instructions sheet. Set BIGHELP_INSTRUCTIONS_EVIDENCE (TEST_RUNNER_…) to a folder to
/// save the screenshots.
///
/// `testEditingSpeed` (only with BIGHELP_SPEED) measures typing and scrolling with the DEBUG probe
/// (`ChatPerformanceRecorder`). Its readings land in the app's Documents as
/// `chat-performance-instructions-<n>.json`: 1 typing in the box, 2 scrolling it, 3 swiping it,
/// 4 typing full screen, 5 scrolling it, 6 swiping it.
final class InstructionsEditingUITests: BighelpUITestCase {
    @MainActor
    func testInstructionsBoxClearsTheKeyboardAndKeepsItWhileScrolling() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let box = openInstructionsBox(in: app)
            XCTAssertGreaterThan((box.value as? String)?.count ?? 0, 3_000, "The long SOUL fixture is loaded")
            box.tap()
            let keyboard = app.keyboards.firstMatch
            guard keyboard.waitForExistence(timeout: 5) else {
                throw XCTSkip("This simulator types with a hardware keyboard")
            }
            Thread.sleep(forTimeInterval: 1)
            // Where the screen has room for it above the keyboard, the whole box clears it.
            let top = app.navigationBars.firstMatch.frame.maxY
            if keyboardTop(app) - top >= box.frame.height + 16 {
                XCTAssertLessThanOrEqual(box.frame.maxY, keyboardTop(app) + 1, "The whole box clears the keyboard")
            }
            save("instructions-box-\(appearance)", app)

            // Back up through the text: a drag down the box that ends in the keyboard.
            box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.05, thenDragTo: keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            XCTAssertFalse(keyboard.waitForNonExistence(timeout: 2), "Scrolling the box keeps the keyboard")
            box.typeText(" Keep receipts.")
            XCTAssertTrue((box.value as? String)?.contains("Keep receipts.") == true)

            // Down through the text: a drag that starts on the box scrolls its text, not the form.
            let frame = box.frame
            box.swipeUp(velocity: .slow)
            XCTAssertEqual(box.frame.minY, frame.minY, accuracy: 2, "A drag on the box scrolls its text")
            XCTAssertTrue(keyboard.exists)

            app.buttons["agent.editor.cancel"].tap()
            let discard = app.buttons["Discard changes"]
            if discard.waitForExistence(timeout: 3) { discard.tap() }
            app.terminate()
        }
    }

    @MainActor
    func testFullScreenInstructionsComeBackToTheBox() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let box = openInstructionsBox(in: app)
            app.buttons["agent.editor.instructions.expand"].tap()
            let editor = app.textViews["agent.editor.instructions.expand.focused"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The full-screen editor starts typing")
            editor.typeText("\nAlways show the total first.")
            save("instructions-full-screen-\(appearance)", app)
            app.buttons["agent.editor.instructions.expand.done"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            XCTAssertTrue((box.value as? String)?.hasSuffix("Always show the total first.") == true,
                          "What was typed full screen is in the box")
            app.buttons["agent.editor.cancel"].tap()
            let discard = app.buttons["Discard changes"]
            XCTAssertTrue(discard.waitForExistence(timeout: 3), "The full-screen edit counts as a change")
            discard.tap()
            app.terminate()
        }
    }

    @MainActor
    func testBotsModeInstructionsSheet() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-long-soul",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance]
            app.launch()
            let primary = app.buttons["simple-bots.primary"]
            XCTAssertTrue(primary.waitForExistence(timeout: 15))
            primary.tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            // The demo chat is still settling right after it opens; a tap then can land before the
            // header takes it.
            let profile = app.descendants(matching: .any)["simple-bots.profile"]
            identity.tap()
            if !profile.waitForExistence(timeout: 3) { identity.tap() }
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            app.buttons["simple-bots.profile.tab.info"].tap()
            let row = app.buttons["simple-bots.profile.instructions"]
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            row.tap()
            let editor = app.textViews["simple-bots.instructions.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let saveButton = app.buttons["simple-bots.instructions.save"]
            XCTAssertFalse(saveButton.isEnabled, "Nothing to save yet")
            editor.tap()
            editor.typeText(" Keep receipts.")
            XCTAssertTrue(saveButton.isEnabled)
            save("instructions-bots-\(appearance)", app)
            // Unsaved instructions stay through a swipe down.
            app.navigationBars["Instructions"].swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertTrue(editor.exists && saveButton.isHittable, "A swipe down keeps the unsaved instructions")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testEditingSpeed() throws {
        guard ProcessInfo.processInfo.environment["BIGHELP_SPEED"] != nil else {
            throw XCTSkip("Speed checks run on request")
        }
        let app = launch(appearance: "light", probe: true)
        let box = openInstructionsBox(in: app)
        box.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        measurePhases(of: box)

        app.buttons["agent.editor.instructions.expand"].tap()
        let editor = app.textViews["agent.editor.instructions.expand.focused"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        measurePhases(of: editor)
    }

    /// Typing, a scroll through the text and back, then real swipes, each its own reading.
    @MainActor
    private func measurePhases(of editor: XCUIElement) {
        Thread.sleep(forTimeInterval: 1.5)
        post(Probe.editorType)
        Thread.sleep(forTimeInterval: 9)
        post(Probe.editorScroll)
        Thread.sleep(forTimeInterval: 10)
        post(Probe.reset)
        for _ in 0..<3 { editor.swipeUp() }
        for _ in 0..<3 { editor.swipeDown() }
        Thread.sleep(forTimeInterval: 1)
        post(Probe.read)
        Thread.sleep(forTimeInterval: 1)
    }

    private enum Probe {
        static let reset = "app.loopdy.fixture.chat-performance.reset"
        static let read = "app.loopdy.fixture.chat-performance.read"
        static let editorType = "app.loopdy.fixture.chat-performance.editor-type"
        static let editorScroll = "app.loopdy.fixture.chat-performance.editor-scroll"
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    @MainActor
    private func launch(appearance: String, probe: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-long-soul",
                               "-loopdy.demo.appearance", appearance]
        if probe {
            app.launchArguments.append("-test-chat-performance-probe")
            app.launchEnvironment["BIGHELP_PERF_LABEL"] = "instructions"
        }
        app.launch()
        return app
    }

    /// Edit Agent for Avery Park, scrolled to the instructions box.
    @MainActor
    private func openInstructionsBox(in app: XCUIApplication) -> XCUIElement {
        openAgents(in: app)
        let more = app.buttons["agent.finance.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        let edit = app.buttons["agent.finance.edit"]
        for _ in 0..<4 where !edit.isHittable {
            app.descendants(matching: .any)["agent.actions.list"].firstMatch.swipeUp()
        }
        edit.tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 5))
        // The form builds its rows as they scroll in.
        let box = app.textViews["agent.editor.instructions"]
        for _ in 0..<6 where !box.exists || !box.isHittable { app.swipeUp() }
        XCTAssertTrue(box.isHittable)
        return box
    }

    /// The top of the keyboard, with the bar above it when there is one.
    @MainActor
    private func keyboardTop(_ app: XCUIApplication) -> CGFloat {
        var top = app.keyboards.firstMatch.frame.minY
        let done = app.buttons["Dismiss keyboard"].firstMatch
        if done.exists, done.frame.maxY <= top + 1 { top = min(top, done.frame.minY - 6) }
        return top
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_INSTRUCTIONS_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
