import XCTest

/// Agents' apps on a real, isolated Hermes with the bighelp plugin and a scripted model, started by
/// `Scripts/HostSignInMatrixProbe.py --modes apps --plugin <plugin checkout>` (BIGHELP_SIGNIN_PROBE).
/// The agent shows a page of about 5 MB that it wrote as a file, the app loads it from the plugin in
/// pieces through the real HTTP path, and the page's answer reaches the agent after Send. Skipped
/// without the probe.
final class HTMLAppsHostUITests: BighelpUITestCase {
    @MainActor
    func testABigAppFromTheAgentOpensAndItsAnswerReachesTheAgent() throws {
        let app = try openChat()
        send("app test", in: app)
        let open = app.buttons["html-app.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 90), "The agent's app shows as a card")
        save("apps-1-card", app)

        open.tap()
        let sendPick = app.webViews.buttons["Send my pick"].firstMatch
        XCTAssertTrue(sendPick.waitForExistence(timeout: 90), "The 5 MB page loads from the computer in pieces")
        XCTAssertFalse(app.staticTexts["The app didn't open."].exists)
        save("apps-2-open", app)

        sendPick.tap()
        let confirm = app.buttons["html-app.answer.send"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "The page's answer waits for Send")
        save("apps-3-answer", app)
        confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Sent."].firstMatch.waitForExistence(timeout: 10),
                      "The page learns the answer went")
        app.buttons["html-app.done"].firstMatch.tap()
        XCTAssertTrue(message(containing: "I got your answers", in: app).waitForExistence(timeout: 60),
                      "The agent got the answer as the person's next message")
        save("apps-4-agent-heard", app)
    }

    // MARK: Helpers

    private var probe: [String: String] = [:]

    @MainActor private func openChat() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes apps")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "apps" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "System prompts") { dialog in
            for label in ["Continue", "Not Now", "Don't Allow"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
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
        // The home's New chat, beside the bar; it opens with nobody picked.
        let newChat = app.buttons["home.new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 20), "The home opens")
        newChat.tap()
        confirmNewChatPicker(in: app)
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20), "A chat opens")
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText(text)
        app.buttons["chat.send"].tap()
    }

    @MainActor private func message(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
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
