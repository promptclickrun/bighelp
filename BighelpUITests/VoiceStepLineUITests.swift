import XCTest

/// Voice mode on demo data: while the agent works, one line under the bars names its
/// step in plain words and replaces itself; a helper's own steps never show. Needs the
/// microphone allowed for bighelp on the simulator. Set BIGHELP_VOICE_EVIDENCE
/// (TEST_RUNNER_…) to save screenshots.
final class VoiceStepLineUITests: BighelpUITestCase {
    @MainActor
    func testVoiceShowsTheAgentsStepOneAtATime() throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-test-voice-steps",
                                "-test-voice-partial", "-loopdy.home.opens-chat", "YES",
                                "-loopdy.voice.conversation-mode", "turnBased",
                                "-bighelp.voice.transcription", "hermes"]
        app.launch()
        let voice = app.buttons["chat.voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 20))
        voice.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voice.screen"].waitForExistence(timeout: 10))
        // Speech recognition can't be allowed ahead of time.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let sendNow = app.buttons["voice.send-now"]
        XCTAssertTrue(sendNow.waitForExistence(timeout: 10), "The demo hears a sentence")
        save("voice-1-hearing", app)
        sendNow.tap()

        let step = app.descendants(matching: .any)["voice.step"]
        XCTAssertTrue(waitFor(step, label: "Checking your calendars…"), "The first step shows: \(step.label)")
        save("voice-2-step-calendar", app)
        XCTAssertTrue(waitFor(step, label: "Asking another agent…"), step.label)
        // The helper reads a file of its own meanwhile; that stays in its folder.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            XCTAssertFalse(step.exists && step.label.hasPrefix("Reading"), "A helper's step showed: \(step.label)")
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(waitFor(step, label: "Cloning weather-app…"), step.label)
        save("voice-3-step-clone", app)
        XCTAssertTrue(waitFor(step, label: "Checking the weather…"), step.label)

        // The reply replaces the steps.
        let caption = app.staticTexts["voice.caption"]
        let replied = NSPredicate(format: "label CONTAINS %@", "Tomorrow looks sunny")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: replied, object: caption)],
                                      timeout: 15), .completed, "The reply shows: \(caption.label)")
        let cleared = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: step)],
                                      timeout: 5), .completed, "The step line clears once the agent answers")
        save("voice-4-reply", app)
    }

    @MainActor private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 12) -> Bool {
        let shows = NSPredicate(format: "exists == true AND label == %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shows, object: element)],
                              timeout: timeout) == .completed
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VOICE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
