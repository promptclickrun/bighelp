import XCTest

/// Delete Agent from a bot's profile in Bots mode, on the demo's agents (#949): the agent goes,
/// its editor and profile close, and the person is back on the Bots home, never on a page that
/// says "This bot isn't here anymore".
final class AgentDeletionUITests: BighelpUITestCase {
    @MainActor
    func testDeletingABotFromItsProfileGoesBackToTheBotsHome() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        let home = app.descendants(matching: .any)["simple-bots.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        let bot = app.buttons["simple-bots.bot.travel"]
        XCTAssertTrue(bot.waitForExistence(timeout: 10))

        // Its profile, straight from the home.
        bot.press(forDuration: 1.2)
        let profileItem = app.buttons["Bot Profile"].firstMatch
        XCTAssertTrue(profileItem.waitForExistence(timeout: 5))
        profileItem.tap()
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10))

        app.buttons["simple-bots.profile.more"].tap()
        let edit = app.buttons["Edit Name and Role"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        // Delete Agent is the editor's last row, which the form builds once it scrolls there.
        XCTAssertTrue(app.buttons["agent.editor.save-template"].firstMatch.waitForExistence(timeout: 10)
                      || app.navigationBars.firstMatch.waitForExistence(timeout: 5), "The editor opens")
        let delete = app.buttons["agent.editor.delete"]
        for _ in 0..<8 where !(delete.exists && delete.isHittable) { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["agent.editor.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Back where the profile opened from, with the bot gone.
        XCTAssertTrue(delete.waitForNonExistence(timeout: 10), "The editor closes")
        XCTAssertTrue(profile.waitForNonExistence(timeout: 10), "The profile closes")
        XCTAssertTrue(home.waitForExistence(timeout: 5), "The Bots home is back")
        XCTAssertFalse(app.staticTexts["This bot isn't here anymore"].exists)
        XCTAssertTrue(bot.waitForNonExistence(timeout: 5), "The bot left the list")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "agent-deleted-back-home"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }
}
