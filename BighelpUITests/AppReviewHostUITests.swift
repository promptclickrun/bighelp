import XCTest

/// The App Review host: bighelp connects with its address alone (no username,
/// password or token), the agent replies, and the plugin's screens load. Run it before each App
/// Store submission. Set BIGHELP_REVIEW_HOST (TEST_RUNNER_…) to the address;
/// skipped without it. Uninstall bighelp from the simulator first, so it starts
/// at the welcome. Set BIGHELP_REVIEW_EVIDENCE to save screenshots.
final class AppReviewHostUITests: BighelpUITestCase {
    @MainActor
    func testTheAddressAloneConnectsAndPluginScreensLoad() throws {
        guard let address = ProcessInfo.processInfo.environment["BIGHELP_REVIEW_HOST"] else {
            throw XCTSkip("Set BIGHELP_REVIEW_HOST to the App Review host's address")
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: address)
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "The agent's chat opens")
        save("1-chat", app)

        // A message gets a real reply from the host's model.
        composer.tap()
        composer.typeText("Say hello in five words.")
        app.buttons["chat.send"].tap()
        let reply = app.textViews.matching(NSPredicate(format: "identifier == %@ AND NOT (value CONTAINS %@)",
                                                       "chat.message.inline-selection", "Say hello")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "The agent replies")
        save("1-reply", app)

        for name in ["feed", "workflows"] {
            if name == "feed" { openRootTab("tab.feed", in: app) } else { app.open(URL(string: "loopdy://workflows")!) }
            // Plugin screens show their error within a few seconds of opening.
            sleep(6)
            save("2-\(name)", app)
            for failure in ["Your Hermes host is running an older bighelp plugin", "Workflows aren't available",
                            "Hermes returned an unsupported or invalid response"] {
                XCTAssertFalse(text(failure, in: app).exists, "\(name): \(failure)")
            }
            XCTAssertFalse(app.alerts.firstMatch.exists, "\(name): an alert showed")
        }
    }

    @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_REVIEW_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("review-host-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
