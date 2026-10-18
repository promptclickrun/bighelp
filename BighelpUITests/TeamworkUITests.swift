import XCTest

/// Settings › Teamwork on demo data: off by default, and on says how many
/// agents now know each other; in full Settings and in Simple Bot mode's.
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
        teamwork.switches.firstMatch.tap()
        let on = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Your 3 agents know each other")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 5))
        XCTAssertEqual(teamwork.value as? String, "1")
    }

    @MainActor
    func testTeamworkInSimpleBotModeSpeaksOfBots() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        let settingsButton = app.buttons["simple-bots.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 15))
        settingsButton.tap()
        let teamwork = app.switches["settings.teamwork"]
        XCTAssertTrue(teamwork.waitForExistence(timeout: 10))
        teamwork.switches.firstMatch.tap()
        let on = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "Your 3 bots know each other")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 5))
    }
}
