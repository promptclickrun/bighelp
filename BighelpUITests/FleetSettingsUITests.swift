import XCTest

/// Settings › Fleet settings in the all-hosts demo: every host's plugin
/// updates at once, each host that needs it shows Restart, and a restart
/// ends in done. Demo hosts: Home Hermes and Studio Mac (both a plugin
/// release behind) and Office Linux (out of reach, skipped).
/// BIGHELP_FLEET_SETTINGS_SHOTS (TEST_RUNNER_…) names a folder for screenshots;
/// BIGHELP_FLEET_SETTINGS_APPEARANCE picks light or dark.
final class FleetSettingsUITests: BighelpUITestCase {
    @MainActor
    func testFleetSettingsUpdatesThePluginEverywhereThroughRestart() throws {
        let environment = ProcessInfo.processInfo.environment
        let appearance = environment["BIGHELP_FLEET_SETTINGS_APPEARANCE"] ?? "light"
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-use-multi-host-fixtures",
                               "-bighelp.hosts.all-hosts", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()

        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let allHosts = app.buttons["menu.all-hosts"]
        XCTAssertTrue(allHosts.waitForExistence(timeout: 5))
        allHosts.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].waitForExistence(timeout: 5))

        // Settings asks which host, and offers settings for every host first.
        menu.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let fleetSettings = app.buttons["fleet.gate.fleet-settings"]
        XCTAssertTrue(fleetSettings.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.gate.host.Home Hermes"].exists, "The hosts are still listed")
        save("settings-popup-\(appearance)", app)
        fleetSettings.tap()
        XCTAssertTrue(app.navigationBars["Fleet settings"].waitForExistence(timeout: 5))

        let homePlugin = status("fleet.settings.plugin.Home Hermes", in: app)
        XCTAssertTrue(wait(for: homePlugin, toRead: "2.19.0 → 2.20.1"), homePlugin.label)
        XCTAssertTrue(wait(for: status("fleet.settings.hermes.Home Hermes", in: app), toRead: "12 commits behind"))
        let office = status("fleet.settings.plugin.Office Linux", in: app)
        XCTAssertTrue(office.label.contains("Offline"), "A host out of reach says so: \(office.label)")
        save("checked-\(appearance)", app)

        // Update every host at once; each one that needs it offers Restart.
        let updateAll = app.buttons["fleet.settings.plugin.update-all"]
        XCTAssertTrue(updateAll.isEnabled)
        updateAll.tap()
        let restartHome = app.buttons["fleet.settings.plugin.Home Hermes.restart"]
        XCTAssertTrue(restartHome.waitForExistence(timeout: 10), "Home Hermes needs a restart")
        XCTAssertTrue(app.buttons["fleet.settings.plugin.Studio Mac.restart"].waitForExistence(timeout: 10))
        XCTAssertTrue(homePlugin.label.contains("Needs restart"), homePlugin.label)
        XCTAssertFalse(app.buttons["fleet.settings.plugin.Office Linux.restart"].exists, "Offline hosts are skipped")
        XCTAssertTrue(office.label.contains("Offline"), office.label)
        save("needs-restart-\(appearance)", app)

        // Restart one host: it restarts, then reads done; the other still waits.
        restartHome.tap()
        let confirm = app.buttons["fleet.settings.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(wait(for: homePlugin, toRead: "Updated · 2.20.1", timeout: 10), homePlugin.label)
        XCTAssertFalse(restartHome.exists)
        XCTAssertTrue(app.buttons["fleet.settings.plugin.Studio Mac.restart"].exists, "Studio Mac still needs its own restart")
        save("done-\(appearance)", app)

        // Hermes updates the same way: every host at once, with its own progress.
        app.buttons["fleet.settings.hermes.update-all"].tap()
        let confirmUpdate = app.buttons["fleet.settings.confirm"].firstMatch
        XCTAssertTrue(confirmUpdate.waitForExistence(timeout: 5))
        confirmUpdate.tap()
        let homeHermes = status("fleet.settings.hermes.Home Hermes", in: app)
        XCTAssertTrue(wait(for: homeHermes, toRead: "Updat"), homeHermes.label)
        save("hermes-updating-\(appearance)", app)
        XCTAssertTrue(wait(for: homeHermes, toRead: "Updated · 0.21.5", timeout: 15), homeHermes.label)
        XCTAssertTrue(app.buttons["fleet.settings.hermes.Studio Mac.restart"].waitForExistence(timeout: 15),
                      "Studio Mac's gateway still runs the old Hermes")
        save("hermes-done-\(appearance)", app)
    }

    @MainActor private func status(_ row: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["\(row).status"].firstMatch
    }

    @MainActor private func wait(for element: XCUIElement, toRead text: String, timeout: TimeInterval = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                timeout: timeout) == .completed
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_FLEET_SETTINGS_SHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("fleet-settings-\(name).png")
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
