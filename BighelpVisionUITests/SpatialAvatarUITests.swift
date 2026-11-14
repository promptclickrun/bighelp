import XCTest

/// Vision Pro: bighelp starts in its own window. Simple mode (☰ or Settings)
/// leaves just the agent standing in the room in its own volume. A quick pinch
/// types or talks (Settings decides); pinch-and-hold explains moving it.
/// Tests run in name order; voice goes last because its one-time speech
/// permission prompt (which the simulator can't pre-grant) covers later tests.
/// Screenshots: XCUIScreen returns a blank image on visionOS, so with
/// BIGHELP_VISION_EVIDENCE set (TEST_RUNNER_…) each step writes
/// "<name>.request" there and waits for a helper on the Mac to answer with
/// "<name>.png" from `simctl io screenshot`.
final class SpatialAvatarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func test0StartsInBighelpAndSimpleModeIsYourChoice() throws {
        let app = launch(pinch: "type")
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "Bighelp opens in its own window")
        let avatar = app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch
        XCTAssertFalse(avatar.waitForExistence(timeout: 5), "The agent doesn't step in by itself")
        save("0-starts-in-bighelp", app)

        enterSimpleMode(app)
        XCTAssertTrue(avatar.waitForExistence(timeout: 15), "Simple mode brings the agent into the room")
        let openApp = app.buttons["spatial-avatar.open-app"].firstMatch
        XCTAssertTrue(openApp.waitForExistence(timeout: 10), "The agent offers the way back")
        XCTAssertFalse(menu.exists, "Bighelp's window closes in simple mode")
        save("0-simple-mode", app)
        // XCUITest can't tap inside a volume once it's the app's only window ("invalid scene
        // world transform"), so Open bighelp is checked on a device, not here.
    }

    @MainActor
    func test2PinchToTypeSendsAndShowsTheReply() throws {
        let app = showAgentBesideBighelp(pinch: "type")
        let avatar = app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20), "The agent steps in beside Bighelp")
        let status = app.descendants(matching: .any)["spatial-avatar.status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        waitFor(status, labelContains: "Pinch to type")
        save("1-in-the-room", app)

        avatar.tap()
        let field = app.textFields["spatial-avatar.prompt.field"].firstMatch.exists
            ? app.textFields["spatial-avatar.prompt.field"].firstMatch
            : app.textViews["spatial-avatar.prompt.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "A quick pinch opens the message box")
        field.tap()
        field.typeText("What's on my calendar today?")
        save("2-typing", app)
        app.buttons["spatial-avatar.prompt.send"].firstMatch.tap()

        let reply = app.descendants(matching: .any)["spatial-avatar.reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), "The answer shows above the agent")
        sleep(2)
        save("3-reply", app)
        XCTAssertFalse(app.descendants(matching: .any)["spatial-avatar.prompt"].firstMatch.isHittable,
                       "The message box closes after sending")

        avatar.press(forDuration: 1.2)
        let tip = app.descendants(matching: .any)["spatial-avatar.move-tip"].firstMatch
        XCTAssertTrue(tip.waitForExistence(timeout: 5), "Pinch and hold explains moving and anchoring")
        save("4-move-tip", app)
    }

    @MainActor
    func test3PinchToTalkOpensVoiceBesideTheAgent() throws {
        let app = showAgentBesideBighelp(pinch: "talk")
        let avatar = app.descendants(matching: .any)["spatial-avatar.avatar"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 20))
        let status = app.descendants(matching: .any)["spatial-avatar.status"].firstMatch
        waitFor(status, labelContains: "Pinch to talk")
        avatar.tap()
        waitFor(status, labelContains: "Listening")
        // Voice is attached to the agent's volume, so it shows beside the agent at once.
        // (It used to open as its own window that landed out of view until the agent moved.)
        // The simulator's one-time microphone and speech prompts can't be pre-granted or
        // answered here, and while one is up the panel is sometimes missing from queries
        // even though it shows; the screenshots are the evidence then.
        let voice = app.descendants(matching: .any)["voice.screen"].firstMatch
        let queryable = voice.waitForExistence(timeout: 15)
        sleep(2)
        save("5-voice", app)
        guard queryable else { return }
        save("6-voice-listening", app)
        let end = app.buttons["voice.end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5) && end.isHittable, "End is reachable right away")
        end.tap()
        XCTAssertTrue(voice.waitForNonExistence(timeout: 10), "Ending voice closes the panel")
        save("7-voice-ended", app)
    }

    @MainActor
    func test1SettingsChoosesWhatAPinchDoes() throws {
        let app = launch(pinch: "talk")
        // ☰ opens the same side menu as on iPad.
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.drawer"].firstMatch.waitForExistence(timeout: 5))
        sleep(1)
        save("7-menu", app)
        app.terminate()

        let settingsApp = launch(pinch: "talk", extra: ["-initial-tab", "profile"])
        let screen = settingsApp.descendants(matching: .any)["settings.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 15))
        let list = settingsApp.collectionViews.firstMatch
        let picker = settingsApp.descendants(matching: .any)["settings.spatial-avatar.pinch"].firstMatch
        for _ in 0..<8 where !picker.exists { list.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Settings has the pinch choice on Vision Pro")
        sleep(1)
        save("8-settings", settingsApp)
        settingsApp.buttons["Type"].firstMatch.tap()
        // Bring the agent in beside bighelp to see the choice take effect.
        let show = settingsApp.switches["settings.spatial-avatar.show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
        let status = settingsApp.descendants(matching: .any)["spatial-avatar.status"].firstMatch
        waitFor(status, labelContains: "Pinch to type")
    }

    // MARK: Helpers

    /// Settings › In your space › Show your agent in the room: the agent stands
    /// beside bighelp, so XCUITest can still tap inside its volume.
    @MainActor
    private func showAgentBesideBighelp(pinch: String) -> XCUIApplication {
        let app = launch(pinch: pinch, extra: ["-initial-tab", "profile"])
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 15))
        let list = app.collectionViews.firstMatch
        let show = app.switches["settings.spatial-avatar.show"].firstMatch
        for _ in 0..<8 where !show.exists { list.swipeUp() }
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Settings can bring the agent in")
        (show.switches.firstMatch.exists ? show.switches.firstMatch : show).tap()
        return app
    }

    /// ☰ › Simple mode: bighelp's window closes and the agent steps in.
    @MainActor
    private func enterSimpleMode(_ app: XCUIApplication) {
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "Bighelp opens in its own window")
        menu.tap()
        let row = app.buttons["menu.simple-mode"].firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "☰ offers Simple mode")
        row.tap()
    }

    @MainActor
    private func launch(pinch: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra + [
            "-use-demo-fixtures", "-disable-demo-delays",
            "-loopdy.home.opens-chat", "NO", "-loopdy.settings.nerd-mode", "NO",
            "-loopdy.voice.conversation-mode", "turnBased",
            "-bighelp.spatial-avatar.pinch-action", pinch,
        ]
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, labelContains text: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VISION_EVIDENCE"] else { return }
        let base = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let shot = base.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: shot)
        FileManager.default.createFile(atPath: base.appendingPathComponent("\(name).request").path, contents: nil)
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: shot.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }
}
