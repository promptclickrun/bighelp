import XCTest

/// Home screen widget links against a real, isolated Hermes host
/// (Scripts/HostSignInMatrixProbe.py --modes widgets). The app runs without
/// demo fixtures, as on a phone: real onboarding, the host's own chat IDs,
/// notifications set up. Skipped without the probe.
final class WidgetLinkHostUITests: BighelpUITestCase {
    @MainActor
    func testRecentChatAndNewChatWidgetLinksOpenChats() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes widgets")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "widgets" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))

        // A chat with a reply, like the ones a widget lists: the primary bot's, from Bots.
        showBots(in: app)
        let primary = app.primaryBot
        XCTAssertTrue(primary.waitForExistence(timeout: 30), "Bots shows the primary bot")
        primary.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The bot's chat opens")
        composer.tap()
        composer.typeText("Widget link fixture message")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(text("Direct streaming fixture complete.", in: app).waitForExistence(timeout: 90), "The agent replies")
        let chatID = try recentChatID(app)
        XCTAssertTrue(chatID.hasPrefix("native-session-v1:"), chatID)
        save("widget-1-chat", app)

        // Recent chat on the widget, with the app still running behind it.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(3)
        XCUIDevice.shared.system.open(chatURL(chatID))
        expectNoAlert(in: app, "Recent chat link")
        XCTAssertTrue(text("Widget link fixture message", in: app).waitForExistence(timeout: 20),
                      "The widget's chat opens")
        save("widget-2-recent-chat", app)

        // New Chat on the widget after the app closed its host connection (past the grace period).
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(35)
        XCUIDevice.shared.system.open(URL(string: "loopdy://new-chat")!)
        expectNoAlert(in: app, "New Chat link")
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The widget opens a new chat")
        XCTAssertFalse(text("Widget link fixture message", in: app).exists, "It's a new chat, not the old one")
        composer.tap()
        composer.typeText("Hello from the widget")
        let send = app.buttons["chat.send"]
        wait(for: [expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)], timeout: 15)
        save("widget-3-new-chat", app)

        // A notification's old dashboard link opens the agent's chat, not Activity.
        XCUIDevice.shared.system.open(URL(string: "loopdy:///dashboard?eventId=fixture")!)
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 15), "The agent's chat, not Activity")
        XCTAssertFalse(app.navigationBars["Activity"].exists)
        save("widget-4-dashboard-link", app)

        // iOS relaunches the app to open a widget link: the chat still opens.
        app.terminate()
        app.open(chatURL(chatID))
        expectNoAlert(in: app, "Recent chat link at launch")
        XCTAssertTrue(text("Widget link fixture message", in: app).waitForExistence(timeout: 30),
                      "The widget's chat opens after a relaunch")
        save("widget-5-relaunch", app)

        // A chat that's gone, at launch: the error closes onto the home and its bar, never a dead end.
        app.terminate()
        app.open(chatURL("native-session-v1:missing:bWlzc2luZw:bWlzc2luZw"))
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "A missing chat explains itself")
        sleep(3) // the agent's chat would open under the alert here
        alert.buttons["OK"].tap()
        let newChat = app.buttons["home.new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 10), "The home is there after the error")
        XCTAssertTrue(newChat.isHittable)
        save("widget-6-after-error", app)
    }

    /// The first row in Chats, as the widget stores it (`chats.row.here/<id>` for the computer in use).
    @MainActor private func recentChatID(_ app: XCUIApplication) throws -> String {
        goBackFromChat(in: app)
        showChats(in: app)
        let prefix = "chats.row.here/"
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The chat is listed")
        let id = String(row.identifier.dropFirst(prefix.count))
        // Back to the agent's chat, where the app sits when someone leaves it.
        row.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20))
        return id
    }

    private func chatURL(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "loopdy"
        components.host = "chat"
        components.path = "/" + id
        return components.url!
    }

    @MainActor private func expectNoAlert(in app: XCUIApplication, _ what: String) {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 8) {
            save("widget-alert-\(what)", app)
            XCTFail("\(what) showed: " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
            alert.buttons.firstMatch.tap()
        }
    }

    @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value))
            .firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
