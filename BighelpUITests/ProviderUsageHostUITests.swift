import XCTest

/// Provider usage against a real, isolated Hermes host with the bighelp plugin
/// (Scripts/HostSignInMatrixProbe.py --modes features), set up as on a phone:
/// no demo fixtures, and the agent's chat opens at launch, covering the home
/// screen. Usage must load from that chat now, after a reconnect, and after a
/// relaunch. Skipped without the probe.
final class ProviderUsageHostUITests: BighelpUITestCase {
    @MainActor func testUsageLoadsFromTheChatTheAppOpensWith() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes features")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "features" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 30), "The agent's chat opens")
        try expectUsage(in: app, "usage-1-after-setup")

        // Past the grace period the app closes its host connection; coming back reconnects.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(35)
        app.activate()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 30))
        try expectUsage(in: app, "usage-2-after-reconnect")

        // A relaunch opens the agent's chat over the home screen before the host is ready.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 45), "The chat opens at launch")
        try expectUsage(in: app, "usage-3-after-relaunch")
    }

    @MainActor private func expectUsage(in app: XCUIApplication, _ name: String) throws {
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        let usage = app.buttons["chat.provider-usage"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if chatMenuItem("chat.provider-usage", in: app, timeout: 3).exists { break }
            app.tap() // close the menu; the entry shows once the host connects
        } while Date() < deadline
        XCTAssertTrue(usage.exists, "Usage is in the chat's ⋯ menu (\(name))")
        usage.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage"].waitForExistence(timeout: 10))
        let failed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "couldn't be loaded")).firstMatch
        let loaded = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Updated")).firstMatch
        let wait = Date().addingTimeInterval(40)
        while Date() < wait, !failed.exists, !loaded.exists { Thread.sleep(forTimeInterval: 0.5) }
        save(name, app)
        XCTAssertFalse(failed.exists, "Usage loads (\(name))")
        XCTAssertTrue(loaded.exists, "Usage shows when it was updated (\(name))")
        // The host's own analytics fill the page too.
        XCTAssertTrue(app.descendants(matching: .any)["usage.hero"].waitForExistence(timeout: 30), "Hermes usage loads (\(name))")
        app.navigationBars.buttons.element(boundBy: 0).tap()
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
