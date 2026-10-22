import XCTest

/// A group chat against a real, throwaway Hermes on one of its two `groups.*` paths
/// (docs/HERMES_BOT_MODE.md). Skipped unless `BIGHELP_GROUPS_HOST` names a JSON file:
///
/// - `address`: the host. A `hermes serve` dashboard answers on the older path; v0.22.4's
///   gateway listener on the session path, and it withholds its token, so give `token`.
/// - `path`: `legacy` or `session`, what that address answers.
/// - `control`: a file a harness watches. The test writes `crash <gateway|serve>` mid-turn;
///   the harness kills that host process, starts it again and writes `restarted`.
/// - `evidence`: a folder for screenshots.
///
/// Its agents `default` and `nova` answer through a scripted model whose reply names it
/// ("Canned reply from fake-alpha."); a message with SLOW takes about a minute.
final class HermesGroupsHostUITests: BighelpUITestCase {
    private var host: [String: String] = [:]

    @MainActor func testGroupChatCreatesSendsStopsRecoversAndDeletes() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_GROUPS_HOST"] else {
            throw XCTSkip("Needs a throwaway Hermes host (BIGHELP_GROUPS_HOST)")
        }
        host = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let label = host["path"] ?? "host"
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        try connect(app)

        // New group chat with both agents.
        openRootTab("tab.agents", in: app, timeout: 30)
        let create = app.buttons["agents.groups.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "Group chats are offered")
        create.tap()
        let title = app.textFields["bot-mode.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText("Paths \(label)")
        for profile in ["default", "nova"] {
            let participant = app.buttons["bot-mode.create.participant.\(profile)"]
            XCTAssertTrue(participant.waitForExistence(timeout: 10), "\(profile) can join")
            participant.tap()
        }
        save("\(label)-1-new-group", app)
        app.buttons["bot-mode.create.submit"].tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 45), "The group chat opens")

        // Both agents answer.
        try send("@all hello both of you", composer: composer, in: app)
        XCTAssertTrue(reply("fake-alpha.", in: app).waitForExistence(timeout: 120), "default answers")
        XCTAssertTrue(reply("fake-beta.", in: app).waitForExistence(timeout: 120), "nova answers")
        save("\(label)-2-both-answered", app)

        // Stop while the slow answer runs.
        try send("@default SLOW tell me a story", composer: composer, in: app)
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 30), "Stop shows while the agent works")
        sleep(4)
        stop.tap()
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 60), "The room is ready again after Stop")
        sleep(5)
        XCTAssertFalse(reply("This one took a while.", in: app).exists, "The stopped answer never arrives")
        save("\(label)-3-stopped", app)

        // The host stops mid-turn. The older path retries; the session path needs Discard.
        if let control = host["control"] {
            try send("@default SLOW are you still there", composer: composer, in: app)
            XCTAssertTrue(stop.waitForExistence(timeout: 30))
            sleep(4)
            try crash(control, role: label == "session" ? "gateway" : "serve")
            if label == "session" {
                let discard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                               "chat.bot-discard.discard.")).firstMatch
                XCTAssertTrue(discard.waitForExistence(timeout: 120), "Discard shows for the cut-off answer")
                save("\(label)-4-cut-off", app)
                discard.tap()
                let confirm = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                               "chat.bot-discard.confirm.")).firstMatch
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                save("\(label)-5-confirm-discard", app)
                confirm.tap()
                XCTAssertTrue(discard.waitForNonExistence(timeout: 60), "The answer was discarded")
                XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 60))
                try send("@default are you back", composer: composer, in: app)
                let answers = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fake-alpha."))
                expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: answers)
                waitForExpectations(timeout: 120)
            } else {
                let retry = app.buttons["chat.bot-mode.retry"]
                XCTAssertTrue(retry.waitForExistence(timeout: 120), "Retry shows for the cut-off answer")
                save("\(label)-4-cut-off", app)
                retry.tap()
                XCTAssertTrue(reply("This one took a while.", in: app).waitForExistence(timeout: 150), "The retried answer lands")
                XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 30), "The retry finishes")
            }
            save("\(label)-6-recovered", app)
        }

        // Delete the group.
        swipeBackFromLeadingEdge(in: app)
        openRootTab("tab.agents", in: app, timeout: 20)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                   "agents.group.", "Paths \(label)")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Delete group"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "The group is gone")
        save("\(label)-7-deleted", app)
    }

    @MainActor private func connect(_ app: XCUIApplication) throws {
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(try XCTUnwrap(host["address"]))
        tapConnect(app)
        let next = app.buttons["host-setup.continue"]
        if let token = host["token"] {
            let picker = app.buttons["direct-hermes.auth-picker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 45), "The listener asks how to sign in")
            picker.tap()
            app.buttons["Access token"].tap()
            let secret = app.secureTextFields["direct-hermes.token"]
            XCTAssertTrue(secret.waitForExistence(timeout: 5))
            secret.tap()
            secret.typeText(token)
            tapConnect(app)
        }
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
    }

    @MainActor private func send(_ text: String, composer: XCUIElement, in app: XCUIApplication) throws {
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["chat.send"]
        let deadline = Date().addingTimeInterval(30)
        while !(send.exists && send.isEnabled), Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        send.tap()
    }

    /// Message text is a text view (`chat.message.inline-selection`), so match its value.
    @MainActor private func reply(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch
    }

    private func crash(_ control: String, role: String) throws {
        try "crash \(role)".write(toFile: control, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if (try? String(contentsOfFile: control, encoding: .utf8))?.hasPrefix("restarted") == true { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("The harness didn't restart the host")
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = host["evidence"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
