import XCTest

/// #504 on a real host with the bighelp plugin: Bots mode's home shows a bot working while
/// another Hermes process runs its turn (`hermes -p <bot> chat -q`, started from a terminal on that
/// computer), within a few seconds, and clears when the run ends. The test only watches the home:
/// it opens no chat and sends nothing.
///
/// TEST_RUNNER_BIGHELP_BOT_ACTIVITY_HOST="<address>|<profile ID>" names an open host and the bot to
/// watch; TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=<folder> gets the screenshots, `ready.json` once the
/// home shows the bot idle (start the run then), and `activity-timings.json` (when the bot showed
/// working and idle again, in Unix seconds).
final class BotActivityHostUITests: BighelpUITestCase {
    private var timings: [String: Double] = [:]
    /// What a working face or row says: the kinds of work a turn can show as.
    private static let working = ["Working", "Writing code", "Using tools", "Thinking", "Browsing the web",
                                  "Working with files", "Taking a look", "Remembering", "Sending a message",
                                  "Working with helpers", "Scheduling", "Making images", "Posting an update"]

    @MainActor func testAnotherProcessesTurnShowsOnTheHomeAndClears() throws {
        guard let value = ProcessInfo.processInfo.environment["BIGHELP_BOT_ACTIVITY_HOST"] else {
            throw XCTSkip("Set TEST_RUNNER_BIGHELP_BOT_ACTIVITY_HOST to \"<address>|<profile ID>\"")
        }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 2 else { throw XCTSkip("TEST_RUNNER_BIGHELP_BOT_ACTIVITY_HOST is \"<address>|<profile ID>\"") }
        let (address, profile) = (parts[0], parts[1])
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        try addHost(app, address: address)
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 30))
        let bot = face(of: profile, in: app)
        XCTAssertTrue(bot.waitForExistence(timeout: 30), "\(profile) is on the home")
        XCTAssertTrue(waitUntil(timeout: 30) { !says(bot, Self.working) }, "Idle before the run: \(String(describing: bot.value))")
        save("activity-0-idle", app)
        mark("ready", ["profile": profile, "at": Date().timeIntervalSince1970])

        XCTAssertTrue(waitUntil(timeout: 300) { says(bot, Self.working) }, "\(profile) shows working")
        timings["working"] = Date().timeIntervalSince1970
        save("activity-1-working", app)
        // Its home row (or tile) stays current on its own while the run goes on.
        XCTAssertTrue(waitUntil(timeout: 600) { !says(bot, Self.working) }, "Clears when the run ends")
        timings["idle"] = Date().timeIntervalSince1970
        save("activity-2-cleared", app)
        mark("activity-timings", timings)
    }

    // MARK: Helpers

    /// The bot's row, its pinned tile, or the primary bot on top.
    @MainActor private func face(of profile: String, in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons["simple-bots.bot.\(profile)"], pinned = app.buttons["simple-bots.pinned.\(profile)"]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if row.exists { return row }
            if pinned.exists { return pinned }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return app.buttons["simple-bots.primary"]
    }

    /// The state is the row's or tile's value; its label holds the latest message, which can say anything.
    @MainActor private func says(_ element: XCUIElement, _ words: [String]) -> Bool {
        guard element.exists, let value = element.value as? String else { return false }
        return words.contains { value.contains($0) }
    }

    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    @MainActor private func addHost(_ app: XCUIApplication, address: String) throws {
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(address)
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
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

    @MainActor private func mark(_ name: String, _ value: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).json"))
    }
}
