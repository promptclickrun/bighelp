import XCTest

/// Holding a message floats the reaction bar over it, like Messages' tapback
/// (demo data, no host). BIGHELP_REACTION_APPEARANCE picks light or dark;
/// BIGHELP_REACTION_PAUSE holds each state on screen for `simctl io` screenshots.
final class ChatReactionBarUITests: BighelpUITestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_REACTION_APPEARANCE"] ?? "light" }
    private var pause: UInt32 { UInt32(ProcessInfo.processInfo.environment["BIGHELP_REACTION_PAUSE"] ?? "") ?? 0 }

    @MainActor
    func testHoldingAMessageReactsFromTheBarOverIt() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-native-reaction-ui",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 20))
        conversation.tap()
        let reply = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND label CONTAINS %@", "Room for the conversation"
        )).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))

        reply.press(forDuration: 1)
        let heart = app.buttons["chat.reaction-bar.heart"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "The bar floats over the held message")
        XCTAssertEqual(heart.label, "React with heart")
        XCTAssertTrue(app.buttons["chat.reaction-bar.more"].exists)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 2), "The menu keeps its actions")
        XCTAssertFalse(app.buttons["React"].exists, "Reactions are no longer a menu item")
        XCTAssertLessThan(heart.frame.maxY, reply.frame.minY + 1, "The bar sits over the message")
        sleep(pause)

        heart.tap()
        let badge = app.descendants(matching: .any)["chat.message-reactions.row-102"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "A tap reacts at once")
        XCTAssertTrue(heart.waitForNonExistence(timeout: 5), "and closes the bar")
        sleep(pause)

        reply.press(forDuration: 1)
        XCTAssertTrue(heart.waitForExistence(timeout: 5))
        XCTAssertTrue(heart.isSelected, "The chosen reaction shows chosen")
        sleep(pause)
        heart.tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "Tapping it again takes it away")

        reply.press(forDuration: 1)
        let more = app.buttons["chat.reaction-bar.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.reaction-picker"].waitForExistence(timeout: 5),
                      "+ opens the full emoji choice")
    }

    /// The bubble's edge, outside its text, opens the same menu; the bar sits on
    /// the person's side, and Reply still works.
    @MainActor
    func testHoldingTheEdgeOfYourOwnMessageShowsTheBarOnYourSide() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-native-reaction-ui",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 20))
        conversation.tap()
        let sent = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND label CONTAINS %@", "A calmer chat"
        )).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 10))

        // Below the text, inside the bubble's padding.
        sent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 5)).press(forDuration: 1)
        let heart = app.buttons["chat.reaction-bar.heart"]
        let more = app.buttons["chat.reaction-bar.more"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "The edge of the bubble opens the bar too")
        XCTAssertLessThan(abs(more.frame.maxX - sent.frame.maxX), 24, "The bar lines up with the person's bubble")
        XCTAssertTrue(heart.isHittable, "The bar stays on screen over a message at the top")
        sleep(pause)
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 2))
        reply.tap()
        XCTAssertTrue(heart.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chat.reply-draft.quote"].waitForExistence(timeout: 5),
                      "Reply still quotes the message")
    }
}
