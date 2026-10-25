import XCTest

/// Holding a message offers reactions with its actions
/// (demo data, no host). BIGHELP_REACTION_APPEARANCE picks light or dark;
/// BIGHELP_REACTION_PAUSE holds each state on screen for `simctl io` screenshots.
final class ChatReactionBarUITests: BighelpUITestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_REACTION_APPEARANCE"] ?? "light" }
    private var pause: UInt32 { UInt32(ProcessInfo.processInfo.environment["BIGHELP_REACTION_PAUSE"] ?? "") ?? 0 }

    @MainActor
    func testHoldingAMessageReactsAndOpensAppleEmojiInput() throws {
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
        let heart = app.buttons["React with heart"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "The menu offers quick reactions")
        XCTAssertEqual(heart.label, "React with heart")
        XCTAssertTrue(app.buttons["More reactions"].exists)
        XCTAssertTrue(app.buttons["Reply"].waitForExistence(timeout: 2), "The menu keeps its actions")
        XCTAssertFalse(app.buttons["React"].exists, "Reactions are no longer a menu item")
        assertReactionsDoNotOverlapActions(app)
        sleep(pause)

        heart.tap()
        let badge = app.descendants(matching: .any)["chat.message-reactions.row-102"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "A tap reacts at once")
        XCTAssertTrue(heart.waitForNonExistence(timeout: 5), "and closes the bar")
        sleep(pause)

        reply.press(forDuration: 1)
        XCTAssertTrue(heart.waitForExistence(timeout: 5))

        sleep(pause)
        heart.tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "Tapping it again takes it away")

        reply.press(forDuration: 1)
        let more = app.buttons["More reactions"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.reaction-picker"].waitForExistence(timeout: 5),
                      "+ opens the full emoji choice")
        let search = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search Emoji")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5),
                      "More reactions opens Apple's emoji keyboard directly")
        capture(app, name: "Apple emoji keyboard")
        let emoji = app.keys["😀"].firstMatch
        XCTAssertTrue(emoji.waitForExistence(timeout: 5))
        emoji.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.reaction-picker"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "Choosing an emoji reacts without another confirmation")
        reply.press(forDuration: 1)
        XCTAssertTrue(app.buttons["React with 😀"].waitForExistence(timeout: 5), "A custom reaction stays reachable")
        assertReactionsDoNotOverlapActions(app)
        app.buttons["React with 😀"].tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "The custom reaction toggles off too")

    }

    /// The bubble padding opens the same menu, and Reply still works.
    @MainActor
    func testHoldingTheEdgeOfYourOwnMessageKeepsReplyAvailable() throws {
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
        let heart = app.buttons["React with heart"]
        let more = app.buttons["More reactions"]
        XCTAssertTrue(heart.waitForExistence(timeout: 5), "The edge of the bubble opens the bar too")
        XCTAssertTrue(more.isHittable)
        assertReactionsDoNotOverlapActions(app)
        XCTAssertTrue(heart.isHittable, "The bar stays on screen over a message at the top")
        sleep(pause)
        let reply = app.buttons["Reply"]
        XCTAssertTrue(reply.waitForExistence(timeout: 2))
        reply.tap()
        XCTAssertTrue(heart.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chat.reply-draft.quote"].waitForExistence(timeout: 5),
                      "Reply still quotes the message")
    }

    @MainActor
    func testLongMessageReactionsStayClearOfActionsAtDifferentScrollPositions() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-native-reaction-ui",
                               "-test-long-reaction-message", "-loopdy.demo.appearance", appearance]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 20))
        conversation.tap()
        let message = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND label CONTAINS %@", "Room for the conversation"
        )).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        for offset in [0.25, 0.5, 0.7] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: offset)).press(forDuration: 1)
            XCTAssertTrue(app.buttons["React with heart"].waitForExistence(timeout: 5))
            assertReactionsDoNotOverlapActions(app)
            sleep(pause)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["React with heart"].waitForNonExistence(timeout: 5))
            app.swipeDown()
        }
    }

    @MainActor
    private func assertReactionsDoNotOverlapActions(_ app: XCUIApplication) {
        let heart = app.buttons["React with heart"]
        let more = app.buttons["More reactions"]
        XCTAssertTrue(heart.isHittable)
        XCTAssertTrue(more.isHittable)
        let bar = heart.frame.union(more.frame)
        XCTAssertLessThanOrEqual(bar.maxX, app.buttons["Reply"].frame.maxX + 1, "Every reaction control stays inside the visible menu")
        for title in ["Reply", "Copy to clipboard", "Share…", "Select text", "Fork from here"] {
            let action = app.buttons[title]
            XCTAssertTrue(action.waitForExistence(timeout: 2), title)
            XCTAssertFalse(bar.intersects(action.frame), "Reactions overlap \(title)")
        }
        capture(app, name: "Reactions and actions")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name) - \(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
