import XCTest

/// Settings › Teamwork on demo data: off by default, and its line says what it does.
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
}
