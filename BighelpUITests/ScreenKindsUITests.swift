import XCTest

/// Settings is a sheet over the screen it was opened from: Back steps through its pages, Done
/// closes it and leaves that screen as it was. Demo data.
final class ScreenKindsUITests: BighelpUITestCase {
    @MainActor
    func testSettingsIsASheetWithDone() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "chats"]
        app.launch()
        let chats = app.descendants(matching: .any)["chats.inbox"].firstMatch
        XCTAssertTrue(chats.waitForExistence(timeout: 20))
        openSettings(in: app)
        let done = app.buttons["settings.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Done, top right")
        let appearance = settingsRow("settings.themes", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        // The sheet's own Back: the screen behind it has a navigation bar too.
        let back = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back inside Settings")
        back.tap()
        XCTAssertTrue(app.buttons["settings.themes"].firstMatch.waitForExistence(timeout: 5), "One step back")
        XCTAssertTrue(done.exists, "Still in Settings")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(chats.waitForExistence(timeout: 5), "Done returns to where you were")
    }
}
