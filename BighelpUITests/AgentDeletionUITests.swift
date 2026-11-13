import XCTest

/// Delete bot from a bot's profile on Bots, on the demo's agents (#949): the agent goes, its
/// profile closes, and the person is back on the Bots home, never on a page that says "This bot
/// isn't here anymore".
final class AgentDeletionUITests: BighelpUITestCase {
    @MainActor
    func testDeletingABotFromItsProfileGoesBackToTheBotsHome() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots"]
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

        // ⋯ › Delete bot, then the confirmation's Delete bot.
        app.buttons["simple-bots.profile.more"].tap()
        let delete = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                      "simple-bots.profile.more.delete", "Delete bot")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["simple-bots.profile.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Back where the profile opened from, with the bot gone.
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
