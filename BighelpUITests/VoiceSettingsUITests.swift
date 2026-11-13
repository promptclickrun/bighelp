import XCTest

/// Settings › Voice on the demo data: Hold music (#651), the
/// on-device Phonon voice (#649) and the Advanced section. `BIGHELP_VOICE_EVIDENCE` saves screenshots there.
final class VoiceSettingsUITests: BighelpUITestCase {
    /// Take turns lists Hold music, and every bot's providers start with this iPhone's Phonon,
    /// which downloads before it can be saved.
    @MainActor
    func testHoldMusicAndThePhoneVoiceInVoiceSettings() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 15))
            openVoiceSettings(app)
            let mode = app.segmentedControls["voice.settings.conversation-mode"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            mode.buttons["Take turns"].tap()

            let holdMusic = app.switches["voice.settings.hold-music"]
            XCTAssertTrue(holdMusic.waitForExistence(timeout: 5))
            if !isOn(holdMusic) { holdMusic.switches.firstMatch.tap() }
            holdMusic.switches.firstMatch.tap()
            XCTAssertFalse(isOn(holdMusic))
            save("voice-hold-music-off-\(appearance)", app)
            holdMusic.switches.firstMatch.tap()

            // The voice is its own group under Voice chats and In chats. Scroll slowly: the group loads
            // from the computer, and a fast swipe goes past where it lands.
            let provider = app.buttons["voice.settings.provider"]
            for _ in 0..<12 where !(provider.exists && provider.isHittable) {
                app.swipeUp(velocity: .slow)
                _ = provider.waitForExistence(timeout: 2)
            }
            XCTAssertTrue(provider.waitForExistence(timeout: 20), "The bot's voice settings load")
            provider.tap()
            let phonon = app.buttons["voice.provider.device-phonon-31m-en"]
            XCTAssertTrue(phonon.waitForExistence(timeout: 5), "Phonon isn't in the provider list")
            save("voice-providers-\(appearance)", app)
            phonon.tap()

            let download = app.buttons["voice.settings.on-device-download"]
            XCTAssertTrue(download.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["voice.settings.save"].isEnabled, "Save before the voice is downloaded")
            save("voice-phonon-download-\(appearance)", app)
            app.terminate()
        }
    }

    /// Settings › Voice › Advanced shows only in Nerd Mode, with both switches off and Restart sound disabled
    /// while no call is in progress.
    @MainActor
    func testDebugSectionShowsOnlyInNerdMode() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 15))
            openVoiceSettings(app)
            let report = app.switches["voice.settings.debug.report"]
            let copy = app.switches["voice.settings.debug.copy"]
            let restart = app.buttons["voice.settings.debug.restart"]
            for _ in 0..<6 where !(restart.exists && restart.isHittable) { app.swipeUp() }
            XCTAssertTrue(report.waitForExistence(timeout: 5), "Nerd Mode shows Settings › Voice › Advanced")
            XCTAssertFalse(isOn(report), "Call sound report starts off")
            XCTAssertFalse(isOn(copy), "Copy report button starts off")
            XCTAssertFalse(restart.isEnabled, "Restart sound with no call in progress")
            // The group's footer can sit just under the screen's edge.
            let hint = app.staticTexts["Restart sound works during a Gemini Live call."]
            for _ in 0..<6 where !hint.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(hint.exists)
            save("voice-debug-nerd-on-\(appearance)", app)
            app.terminate()

            let plain = launch(appearance, extra: ["-loopdy.settings.nerd-mode", "NO"])
            XCTAssertTrue(plain.buttons["chat.attachment"].waitForExistence(timeout: 15))
            openVoiceSettings(plain)
            XCTAssertTrue(plain.segmentedControls["voice.settings.conversation-mode"].waitForExistence(timeout: 5))
            for _ in 0..<4 { plain.swipeUp() }
            XCTAssertFalse(plain.switches["voice.settings.debug.report"].exists, "Advanced without Nerd Mode")
            XCTAssertFalse(plain.buttons["voice.settings.debug.restart"].exists, "Advanced without Nerd Mode")
            save("voice-debug-nerd-off-\(appearance)", plain)
            plain.terminate()
        }
    }

    /// Nerd Mode alone puts nothing on the call screen; each Debug switch adds only its own part, and Restart
    /// sound is never there. The demo call (`-test-live-voice-report`) keeps a made-up report.
    @MainActor
    func testCallScreenShowsOnlyWhatTheDebugSwitchesAskFor() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance, extra: ["-test-live-voice", "-test-live-voice-report"])
            let reportText = app.descendants(matching: .any)["live-voice.audio-report"]
            let copyButton = app.buttons["live-voice.audio-report.copy"]
            // Defaults last the whole test: the light pass left both switches on.
            setDebugSwitches(report: false, copy: false, in: app)
            openCall(app)
            sleep(2)
            XCTAssertFalse(reportText.exists, "The report shows with both switches off")
            XCTAssertFalse(copyButton.exists, "Copy report shows with both switches off")
            XCTAssertFalse(app.buttons["Restart sound"].exists)
            save("call-screen-debug-off-\(appearance)", app)
            app.buttons["live-voice.end"].tap()

            setDebugSwitches(report: true, copy: false, in: app)
            openCall(app)
            XCTAssertTrue(reportText.waitForExistence(timeout: 5), "Show call sound report shows the report")
            XCTAssertFalse(copyButton.exists, "Copy report shows without its switch")
            app.buttons["live-voice.end"].tap()

            setDebugSwitches(report: false, copy: true, in: app)
            openCall(app)
            XCTAssertTrue(copyButton.waitForExistence(timeout: 5), "Copy report button shows Copy report")
            XCTAssertFalse(reportText.exists, "The report shows without its switch")
            app.buttons["live-voice.end"].tap()

            setDebugSwitches(report: true, copy: true, in: app, saving: "voice-debug-switches-on-\(appearance)")
            openCall(app)
            XCTAssertTrue(reportText.waitForExistence(timeout: 5))
            XCTAssertTrue(copyButton.exists)
            XCTAssertFalse(app.buttons["Restart sound"].exists, "Restart sound left the call screen")
            save("call-screen-debug-on-\(appearance)", app)
            app.terminate()

            // The switches stay on, but Nerd Mode is off: nothing shows.
            let plain = launch(appearance, extra: ["-test-live-voice", "-test-live-voice-report",
                                                   "-loopdy.settings.nerd-mode", "NO"])
            openCall(plain)
            sleep(2)
            XCTAssertFalse(plain.descendants(matching: .any)["live-voice.audio-report"].exists)
            XCTAssertFalse(plain.buttons["live-voice.audio-report.copy"].exists)
            plain.terminate()
        }
    }

    /// At XXL, XXXL and the largest accessibility size, the Debug rows and the call screen's report stay whole
    /// inside the screen.
    @MainActor
    func testDebugRowsStayWholeAtLargerText() {
        for size in ["XXL", "XXXL", "AccessibilityXXXL"] {
            let app = launch("light", extra: ["-test-live-voice", "-test-live-voice-report",
                                              "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"])
            setDebugSwitches(report: true, copy: true, in: app, saving: "voice-debug-\(size)", checkingWithin: true)
            openCall(app)
            let copyButton = app.buttons["live-voice.audio-report.copy"]
            XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
            let screen = app.windows.firstMatch.frame
            let report = app.descendants(matching: .any)["live-voice.audio-report"]
            XCTAssertTrue(report.exists)
            XCTAssertGreaterThanOrEqual(report.frame.minX, screen.minX, "\(size): the report starts off screen")
            XCTAssertLessThanOrEqual(report.frame.maxX, screen.maxX, "\(size): the report runs off screen")
            // Scrolled into view, Copy report sits whole above the call's controls.
            let end = app.buttons["live-voice.end"]
            for _ in 0..<8 where copyButton.frame.maxY > end.frame.minY { app.swipeUp() }
            XCTAssertLessThanOrEqual(copyButton.frame.maxY, end.frame.minY, "\(size): Copy report is cut")
            XCTAssertLessThanOrEqual(copyButton.frame.maxX, screen.maxX, "\(size): Copy report is cut")
            save("call-screen-debug-on-\(size)", app)
            app.terminate()
        }
    }

    @MainActor
    private func openCall(_ app: XCUIApplication) {
        let voice = app.buttons["chat.voice"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 15))
        voice.tap()
        XCTAssertTrue(app.buttons["live-voice.end"].waitForExistence(timeout: 15), "The demo call connects")
    }

    @MainActor
    private func setDebugSwitches(report: Bool, copy: Bool, in app: XCUIApplication, saving name: String? = nil,
                                  checkingWithin: Bool = false) {
        XCTAssertTrue(app.buttons["chat.voice"].firstMatch.waitForExistence(timeout: 10))
        openVoiceSettings(app)
        let restart = app.buttons["voice.settings.debug.restart"]
        for _ in 0..<10 where !(restart.exists && restart.isHittable) { app.swipeUp() }
        let screen = app.windows.firstMatch.frame
        for (identifier, on) in [("voice.settings.debug.report", report), ("voice.settings.debug.copy", copy)] {
            let toggle = app.switches[identifier]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if !toggle.isHittable { app.swipeDown() }
            if isOn(toggle) != on { toggle.switches.firstMatch.tap() }
            XCTAssertEqual(isOn(toggle), on)
            if checkingWithin {
                XCTAssertLessThanOrEqual(toggle.frame.maxX, screen.maxX, "\(identifier) runs off screen")
                XCTAssertLessThanOrEqual(toggle.switches.firstMatch.frame.maxX, screen.maxX, "\(identifier)'s switch is cut")
            }
        }
        if checkingWithin {
            for _ in 0..<6 where !restart.isHittable { app.swipeUp() }
            XCTAssertTrue(restart.isHittable, "Restart sound is out of reach")
            XCTAssertLessThanOrEqual(restart.frame.maxX, screen.maxX, "Restart sound runs off screen")
        }
        if let name { save(name, app) }
        // The sheet's own Back: the screen behind Settings has a navigation bar too.
        app.buttons["BackButton"].firstMatch.tap()
        let done = app.buttons["settings.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        // Back into the chat Settings was opened from, for its call.
        let chat = chatRow("demo-finance", in: app)
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "Chats lists the demo chat")
        chat.tap()
    }

    @MainActor
    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-voice-settings-fixture",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openVoiceSettings(_ app: XCUIApplication) {
        // Settings opens from the home's circle: Back out of the chat first.
        goBackFromChat(in: app)
        openSettings(in: app)
        let voice = settingsRow("settings.chat.voice-settings", in: app)
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VOICE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
