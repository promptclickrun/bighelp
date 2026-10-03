import XCTest

/// For a Release build with the phone's 1 MB main-thread stack (see
/// device-stack notes): real onboarding, a real host behind a password proxy,
/// then the chat header, Provider Usage, Settings › Voice with its provider
/// list, Chat layout and Provider Usage settings. Test shortcuts are
/// Debug-only, so this uses none.
/// BIGHELP_RELEASE_WALK is "address|proxy username|proxy password".
final class ReleaseScreensWalkthroughUITests: BighelpUITestCase {
    @MainActor
    func testOnboardingProxyHostChatVoiceAndChatLayout() throws {
        guard let walk = ProcessInfo.processInfo.environment["BIGHELP_RELEASE_WALK"] else {
            throw XCTSkip("Release walkthrough needs a host")
        }
        var parts = walk.components(separatedBy: "|")
        XCTAssertEqual(parts.count, 3)
        guard parts.count == 3 else { return }
        if parts[0].hasPrefix("localhost:") {
            parts[0] = "release-\(UUID().uuidString.prefix(8).lowercased()).\(parts[0])"
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()

        let start = app.buttons["onboarding.get-started"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(parts[0])
        // During onboarding the button reports the screen's identifier.
        let connect = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND label IN %@",
            ["host-setup.connect-host", "host-setup.screen"], ["Continue", "Connect"])).firstMatch
        func tapConnect() {
            for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
            connect.tap()
        }
        tapConnect()
        let username = app.textFields.matching(NSPredicate(
            format: "identifier == %@ OR placeholderValue == %@", "host-setup.proxy-username", "Username")).firstMatch
        for _ in 0..<5 where !username.exists { app.swipeDown() }
        XCTAssertTrue(username.waitForExistence(timeout: 15), "The proxy asks for a password")
        username.tap()
        username.typeText(parts[1])
        let password = app.secureTextFields.matching(NSPredicate(
            format: "identifier == %@ OR placeholderValue == %@", "host-setup.proxy-password-field", "Password")).firstMatch
        password.tap()
        password.typeText(parts[2])
        tapConnect()
        let next = app.buttons.matching(NSPredicate(
            format: "identifier IN %@ AND (label == %@ OR label BEGINSWITH %@)",
            ["host-setup.continue", "host-setup.screen"], "Start chatting", "Let")).firstMatch
        // A Hermes without its own sign-in connects straight away.
        if !next.waitForExistence(timeout: 20), app.staticTexts["Sign in to Hermes"].exists { tapConnect() }
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        next.tap()
        // The chat header the 16 Pro tester found cramped.
        let avatar = app.buttons["agent.hero.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 30), "The agent's chat opens")
        // iOS offers to save the proxy password, sometimes after the chat
        // shows; it covers the chat, so wait for it before tapping on.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<20 {
            if let notNow = [app.buttons["Not Now"], springboard.buttons["Not Now"]].first(where: \.exists) {
                notNow.tap()
                break
            }
            usleep(500_000)
        }
        save("release-1-chat", app)

        // Usage: the page, its charts and every section must open on the phone-sized stack.
        app.buttons["chat.options"].tap()
        let usage = app.buttons["chat.provider-usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        let page = app.descendants(matching: .any)["usage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        _ = app.descendants(matching: .any)["usage.hero"].waitForExistence(timeout: 60)
        sleep(2)
        save("release-5-usage", app)
        for _ in 0..<6 { page.swipeUp() }
        save("release-6-usage-bottom", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 5))

        app.buttons["chat.menu"].tap()
        XCTAssertTrue(app.buttons["menu.done"].waitForExistence(timeout: 5))
        // Settings sits below the fold, past Go to.
        let settingsEntry = app.buttons["menu.settings"]
        for _ in 0..<4 where !(settingsEntry.exists && settingsEntry.isHittable) { app.swipeUp() }
        settingsEntry.tap()
        let mode = app.segmentedControls["settings.voice.mode"]
        for _ in 0..<6 where !(mode.exists && mode.isHittable) { app.swipeUp() }
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["TTS"].tap()
        let voice = settingsRow("settings.chat.voice-settings", in: app)
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        voice.tap()
        let provider = app.buttons["voice.settings.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 20), "The host's speech settings load")
        save("release-2-voice", app)
        provider.tap()
        XCTAssertTrue(app.buttons["voice.provider.piper"].waitForExistence(timeout: 5))
        save("release-3-providers", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let layout = settingsRow("settings.appearance.chat-layout", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        layout.tap()
        XCTAssertTrue(app.segmentedControls["chat-layout.avatar-size"].waitForExistence(timeout: 5))
        save("release-4-chat-layout", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertEqual(app.state, .runningForeground, "No crash on the phone-sized stack")
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_RELEASE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
