import XCTest

/// Settings › Voice and a chat's + menu on the demo data: Auto TTS (#650), Hold music (#651) and
/// the on-device Phonon voice (#649). `BIGHELP_VOICE_EVIDENCE` saves screenshots there.
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

    @MainActor
    private func launch(_ appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-voice-settings-fixture",
                               "-bighelp.settings.simple-bots", "NO", "-loopdy.demo.appearance", appearance]
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
