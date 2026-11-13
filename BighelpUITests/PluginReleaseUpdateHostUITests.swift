import XCTest

/// No app build pins the plugin: against a real, isolated Hermes host running an
/// older plugin (Scripts/HostSignInMatrixProbe.py --modes update), the app finds
/// the latest GitHub Release and installs it. The probe then reads the version and
/// commit on the host. Needs the internet; skipped without the probe.
final class PluginReleaseUpdateHostUITests: BighelpUITestCase {
    @MainActor
    func testUpdatesToTheLatestReleaseOnARealHost() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes update")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "update" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 30), "The agent's chat opens")

        openSettings(in: app)
        // Your computers: the computer's row says so once the check finds a newer release.
        let hosts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'hosts.host.'")).firstMatch
        for _ in 0..<6 where !(hosts.exists && hosts.isHittable) { app.swipeUp() }
        let flagged = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'hosts.host.' AND label CONTAINS 'plugin update available'")).firstMatch
        let flaggedInTime = flagged.waitForExistence(timeout: 30)
        save("update-0-settings", app)
        hosts.tap()
        let reason = app.staticTexts["settings.plugin.status"].firstMatch
        XCTAssertTrue(flaggedInTime, "Settings shows that an update is available: \(reason.waitForExistence(timeout: 5) ? reason.label : "no status")")
        let update = app.buttons["settings.plugin.update"]
        for _ in 0..<6 where !update.waitForExistence(timeout: 5) || !update.isHittable { app.swipeUp() }
        let status = app.staticTexts["settings.plugin.status"].firstMatch
        XCTAssertTrue(update.exists, "An older plugin is offered the latest release: \(status.exists ? status.label : "no status")")
        let latest = app.staticTexts.matching(identifier: "settings.plugin.latest").firstMatch
        let offered = update.label.replacingOccurrences(of: "Update plugin to ", with: "")
        XCTAssertTrue(offered.first?.isNumber == true, "The button names the release: \(update.label)")
        XCTAssertNotEqual(offered, "2.18.2")
        if latest.exists { XCTAssertTrue(latest.label.contains(offered) || (latest.value as? String)?.contains(offered) == true) }
        save("update-1-available", app)

        update.tap()
        let later = app.buttons["Later"].firstMatch
        XCTAssertTrue(later.waitForExistence(timeout: 180), "The update installs, then offers a restart")
        save("update-2-restart", app)
        later.tap()
        let installed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Installed \(offered)")).firstMatch
        for _ in 0..<4 where !installed.exists { app.swipeUp() }
        XCTAssertTrue(installed.waitForExistence(timeout: 10), "The app confirms the new version")
        save("update-3-installed", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
