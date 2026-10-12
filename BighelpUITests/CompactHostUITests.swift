import XCTest

/// ⋯ › Advanced › Compact on a real Hermes host with the bighelp plugin
/// (Scripts/HostSignInMatrixProbe.py --modes features, or a probe file naming any open
/// host). A new chat of its own gets two short turns, then Compact reaches Hermes and ends
/// without an error. Two turns are too few to fold, so Hermes declines at once and the rail
/// may only flash. Skipped without the probe.
final class CompactHostUITests: BighelpUITestCase {
    @MainActor func testCompactFoldsARealChat() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes features")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "features" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "A chat opens")
        let newChat = chatNewChatButton(in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 15))
        newChat.tap()
        confirmNewChatPicker(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 30))

        // Capital letters in the reply only, so the person's own message never matches.
        for word in ["mango", "kiwi"] {
            composer.tap()
            composer.typeText("Reply with only the word \(word) in capital letters.")
            let send = app.buttons["chat.send"]
            let ready = Date().addingTimeInterval(30)
            while !send.isEnabled, Date() < ready { Thread.sleep(forTimeInterval: 0.3) }
            send.tap()
            let reply = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", word.uppercased())).firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 90), "The agent answers \(word)")
        }
        // The turn settles before Compact is offered again.
        var compact = chatCompactItem(in: app)
        let enabled = Date().addingTimeInterval(30)
        while !(compact.exists && compact.isEnabled), Date() < enabled {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)).tap()
            Thread.sleep(forTimeInterval: 1)
            compact = chatCompactItem(in: app)
        }
        XCTAssertTrue(compact.isEnabled, "Advanced has Compact on a real chat")
        save("compact-menu", app)
        compact.tap()

        let running = app.descendants(matching: .any)["chat.compaction.running"].firstMatch
        XCTAssertTrue(running.waitForNonExistence(timeout: 180), "Hermes ends the compaction")
        let failed = app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "couldn't compact")).firstMatch
        XCTAssertFalse(failed.waitForExistence(timeout: 5), "Hermes takes the request")
        save("compact-after", app)
        app.terminate()
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
