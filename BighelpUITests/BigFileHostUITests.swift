import XCTest

/// An 80 MB video on a real, isolated Hermes with the bighelp plugin and a scripted model, started by
/// `Scripts/HostSignInMatrixProbe.py --modes bigfiles --plugin <plugin checkout>` (BIGHELP_SIGNIN_PROBE).
/// The link to the host is slower and drops once mid-upload. The video goes up in pieces while the app
/// is in the background for a while, carries on after the drop, the tile turns into the line, and the
/// agent reads the file with ffprobe from the path Hermes gave it. Skipped without the probe.
final class BigFileHostUITests: BighelpUITestCase {
    @MainActor
    func testAnEightyMegabyteVideoReachesTheAgentAfterADrop() throws {
        let app = try openChat()
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText("video test: how long is this video?")
        app.buttons["chat.send"].tap()

        let progress = app.staticTexts.containing(NSPredicate(format: "label CONTAINS ' of '")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 60), "The tile counts the video up")
        save("bigfiles-1-uploading", app)
        XCTAssertTrue(composer.isHittable, "The message box stays free while the video goes up")

        // Away for a while: the background session keeps sending.
        XCUIDevice.shared.press(.home)
        sleep(15)
        app.activate()
        save("bigfiles-2-back", app)

        let line = app.descendants(matching: .any)["chat.sent-file"]
        XCTAssertTrue(line.waitForExistence(timeout: 300), "Once Hermes has it, the video is a line on the rail")
        XCTAssertFalse(app.descendants(matching: .any)["chat.big-file"].exists, "One look at a time")
        save("bigfiles-3-line", app)

        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'ffprobe says 72' OR value CONTAINS 'ffprobe says 72'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 180), "The agent read the video with its own tools")
        let raw = NSPredicate(format: "label CONTAINS '@file:' OR value CONTAINS '@file:' OR value CONTAINS '/uploads/'")
        XCTAssertEqual(app.descendants(matching: .any).matching(raw).count, 0, "No path or reference as text")
        save("bigfiles-4-agent-read-it", app)

        line.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile.files"].waitForExistence(timeout: 20),
                      "A tap opens the bot's Files")
        save("bigfiles-5-files", app)
    }

    // MARK: Helpers

    private var probe: [String: String] = [:]

    @MainActor private func openChat() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes bigfiles")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "bigfiles", let video = probe["video_file"] else {
            throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode")
        }
        addUIInterruptionMonitor(withDescription: "System prompts") { dialog in
            for label in ["Continue", "Not Now", "Don't Allow"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-test-draft-attachments", "big-file-import", "-test-big-file-path", video]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(try XCTUnwrap(probe["address"]))
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
        let newChat = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["sessions.empty.new-chat", "chat.home.new-chat", "chat.new-chat", "root.new-chat"])).firstMatch
        if newChat.waitForExistence(timeout: 10) {
            newChat.tap()
            confirmNewChatPicker(in: app)
        }
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20), "A chat opens")
        let rail = app.buttons["chat.draft-attachments.rail"]
        XCTAssertTrue(rail.waitForExistence(timeout: 60), "The video waits in the message box")
        XCTAssertTrue(rail.label.contains("Trip to the coast.mov") || rail.label.contains("1 file"), rail.label)
        save("bigfiles-0-attached", app)
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
