import XCTest

/// Settings › Voice and a chat's + menu on the demo data: Auto TTS (#650), Hold music (#651), the
/// on-device Phonon voice (#649) and the Debug section. `BIGHELP_VOICE_EVIDENCE` saves screenshots there.
final class VoiceSettingsUITests: BighelpUITestCase {
    /// The + menu's Auto TTS and Settings › Voice › Use TTS on every response are one switch.
    @MainActor
    func testAutoTTSInThePlusMenuIsTheVoiceSetting() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let plus = app.buttons["chat.attachment"]
            XCTAssertTrue(plus.waitForExistence(timeout: 15))
            plus.tap()
            let menuSwitch = app.switches["chat.action.auto-tts"]
            for _ in 0..<4 where !(menuSwitch.exists && menuSwitch.isHittable) {
                app.descendants(matching: .any)["chat.action-drawer.v3"].firstMatch.swipeUp()
            }
            XCTAssertTrue(menuSwitch.waitForExistence(timeout: 5))
            let wasOn = isOn(menuSwitch)
            menuSwitch.switches.firstMatch.tap()
            XCTAssertNotEqual(isOn(menuSwitch), wasOn, "Auto TTS didn't change in the + menu")
            save("plus-menu-auto-tts-\(appearance)", app)
            app.buttons["chat.action-drawer.done"].tap()

            openVoiceSettings(app)
            let setting = app.switches["voice.settings.auto-tts"]
            XCTAssertTrue(setting.waitForExistence(timeout: 5))
            XCTAssertEqual(isOn(setting), !wasOn, "Settings › Voice shows another value than the + menu")
            app.terminate()
        }
    }

    /// TTS voice mode lists Hold music, and every agent's providers start with this iPhone's Phonon,
    /// which downloads before it can be saved.
    @MainActor
    func testHoldMusicAndThePhoneVoiceInVoiceSettings() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 15))
            openVoiceSettings(app)
            let mode = app.segmentedControls["voice.settings.conversation-mode"]
            XCTAssertTrue(mode.waitForExistence(timeout: 5))
            mode.buttons["TTS"].tap()

            let holdMusic = app.switches["voice.settings.hold-music"]
            XCTAssertTrue(holdMusic.waitForExistence(timeout: 5))
            if !isOn(holdMusic) { holdMusic.switches.firstMatch.tap() }
            holdMusic.switches.firstMatch.tap()
            XCTAssertFalse(isOn(holdMusic))
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@",
                                                                 "The wait for a reply is silent.")).firstMatch.exists)
            save("voice-hold-music-off-\(appearance)", app)
            holdMusic.switches.firstMatch.tap()

            let provider = app.buttons["voice.settings.provider"]
            for _ in 0..<6 where !(provider.exists && provider.isHittable) { app.swipeUp() }
            XCTAssertTrue(provider.waitForExistence(timeout: 20), "The agent's speech settings load")
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

    /// Settings › Voice › Debug shows only in Nerd Mode, with both switches off and Restart sound disabled
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
            XCTAssertTrue(report.waitForExistence(timeout: 5), "Nerd Mode shows Settings › Voice › Debug")
            XCTAssertFalse(isOn(report), "Show call sound report starts off")
            XCTAssertFalse(isOn(copy), "Copy report button starts off")
            XCTAssertFalse(restart.isEnabled, "Restart sound with no call in progress")
            XCTAssertTrue(app.staticTexts["Restart sound works during a Gemini Live call."].exists)
            save("voice-debug-nerd-on-\(appearance)", app)
            app.terminate()

            let plain = launch(appearance, extra: ["-loopdy.settings.nerd-mode", "NO"])
            XCTAssertTrue(plain.buttons["chat.attachment"].waitForExistence(timeout: 15))
            openVoiceSettings(plain)
            XCTAssertTrue(plain.segmentedControls["voice.settings.conversation-mode"].waitForExistence(timeout: 5))
            for _ in 0..<4 { plain.swipeUp() }
            XCTAssertFalse(plain.switches["voice.settings.debug.report"].exists, "Debug without Nerd Mode")
            XCTAssertFalse(plain.buttons["voice.settings.debug.restart"].exists, "Debug without Nerd Mode")
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
        app.navigationBars.buttons.firstMatch.tap()
        let done = app.buttons["settings.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    @MainActor
    private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-voice-settings-fixture",
                               "-bighelp.settings.simple-bots", "NO", "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openVoiceSettings(_ app: XCUIApplication) {
        app.buttons["chat.menu"].tap()
        XCTAssertTrue(app.buttons["menu.done"].waitForExistence(timeout: 5))
        let settingsEntry = app.buttons["menu.settings"]
        for _ in 0..<4 where !(settingsEntry.exists && settingsEntry.isHittable) { app.swipeUp() }
        settingsEntry.tap()
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
