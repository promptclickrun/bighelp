import XCTest

/// Start voice chat hands bighelp a link: the agent's Bot Chat opens in voice
/// straight from the background, with no step in between. On the demo data,
/// where Home Hermes is the demo's own computer and Studio Mac a sample one.
/// Needs the microphone allowed for bighelp on the simulator. Set
/// BIGHELP_VOICE_SHORTCUT_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class VoiceShortcutUITests: BighelpUITestCase {
    private static let homeHermes = "0D0D0D0D-0000-4000-8000-000000000001"
    private static let studioMac = "0D0D0D0D-0000-4000-8000-000000000002"

    @MainActor
    func testVoiceLinkOpensTheAgentsBotChatInVoice() throws {
        let app = launchInBackground()
        app.open(URL(string: "loopdy://voice?agent=finance&host=\(Self.homeHermes)")!)
        let voice = app.descendants(matching: .any)["voice.screen"]
        XCTAssertTrue(voice.waitForExistence(timeout: 20), "Voice opens")
        // Speech recognition can't be allowed ahead of time.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        save("1-voice", app)

        app.buttons["voice.end"].tap()
        let botChat = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "This is the shared Bot Chat."))
            .firstMatch
        XCTAssertTrue(botChat.waitForExistence(timeout: 10), "Under voice is the agent's Bot Chat, not a new chat")
        save("2-bot-chat", app)
    }

    @MainActor
    func testVoiceOnAGatewayThatCantOpenSaysWhy() throws {
        let app = launchInBackground()
        app.open(URL(string: "loopdy://voice?agent=research&host=\(Self.studioMac)")!)
        expectMessage("Studio Mac is a sample host in this demo.", in: app)
        app.open(URL(string: "loopdy://voice?host=0D0D0D0D-0000-4000-8000-0000000000FF")!)
        expectMessage("That computer isn't in bighelp anymore.", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["voice.screen"].exists)
    }

    // MARK: Helpers

    /// Like a Shortcut run: bighelp is in the background when the link arrives.
    @MainActor
    private func launchInBackground() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-canonical-agent-chat",
                               "-loopdy.voice.conversation-mode", "turnBased", "-bighelp.voice.transcription", "hermes"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        return app
    }

    @MainActor
    private func expectMessage(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts["Unable to open"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "A plain message", file: file, line: line)
        XCTAssertTrue(alert.staticTexts[message].exists,
                      alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "), file: file, line: line)
        save("message-\(abs(message.hashValue) % 10_000)", app)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VOICE_SHORTCUT_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("voice-shortcut-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
