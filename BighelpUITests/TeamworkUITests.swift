import XCTest

/// Settings › Teamwork on demo data: off by default, and its line says what it does; the same
/// Settings in Bots mode.
final class TeamworkUITests: BighelpUITestCase {
    @MainActor
    func testTeamworkTurnsOnInSettings() throws {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        openRootTab("tab.profile", in: app)
        let teamwork = app.switches["settings.teamwork"]
        let settings = app.descendants(matching: .any)["settings.screen"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        for _ in 0..<6 where !(teamwork.exists && teamwork.isHittable) { settings.swipeUp() }
        XCTAssertTrue(teamwork.waitForExistence(timeout: 5))
        XCTAssertEqual(teamwork.value as? String, "0", "Off until the person turns it on")
        XCTAssertTrue(teamwork.label.contains("Bots ask each other for help"), teamwork.label)
        teamwork.switches.firstMatch.tap()
        let on = app.switches.matching(NSPredicate(format: "identifier == %@ AND value == '1'", "settings.teamwork")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 5))
    }

    @MainActor
    func testTeamworkInBotsModeIsTheSameSwitch() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        let settingsButton = app.buttons["simple-bots.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        let teamwork = app.switches["settings.teamwork"]
        XCTAssertTrue(teamwork.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.exists, "Bots mode opens the one Settings")
        teamwork.switches.firstMatch.tap()
        let on = app.switches.matching(NSPredicate(format: "identifier == %@ AND value == '1'", "settings.teamwork")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 5))
    }
}
