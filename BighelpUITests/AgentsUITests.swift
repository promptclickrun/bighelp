import XCTest
import UIKit

/// Group chats opened from Bots on the demo data: who is typing, and Stop again after a lost Stop.
final class AgentsUITests: BighelpUITestCase {
    /// Bots › the group chat whose row names `title`.
    @MainActor
    private func openGroupFromBots(titled title: String, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        showBots(in: app)
        let home = app.descendants(matching: .any)["simple-bots.home"].firstMatch
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                     "simple-bots.group.", title)).firstMatch
        _ = group.waitForExistence(timeout: 8)
        for _ in 0..<8 where !(group.exists && group.isHittable) { home.swipeUp() }
        XCTAssertTrue(group.exists && group.isHittable, "Bots lists \(title)", file: file, line: line)
        guard group.exists else { return }
        group.tap()
    }

    /// Each member Hermes reports writing gets its own "is typing" row; the
    /// old "Agents are collaborating" line is gone.
    @MainActor
    func testGroupShowsWhoIsTyping() {
        for appearance in ["light", "dark"] { checkGroupShowsWhoIsTyping(appearance: appearance) }
    }

    @MainActor
    private func checkGroupShowsWhoIsTyping(appearance: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-agents-directory",
                               "-preview-group-typing", "-loopdy.home.landing", "bots",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        openGroupFromBots(titled: "Research circle", in: app)
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        let typing = app.descendants(matching: .any).matching(identifier: "chat.bot-typing")
        let two = NSPredicate(format: "count == 2")
        expectation(for: two, evaluatedWith: typing)
        waitForExpectations(timeout: 10)
        for index in 0..<2 {
            XCTAssertTrue(typing.element(boundBy: index).label.hasSuffix(" is typing"),
                          typing.element(boundBy: index).label)
        }
        XCTAssertFalse(app.staticTexts["Agents are collaborating"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "group-typing-\(appearance)"
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    /// A Stop whose answer is lost leaves the group chat one way back, Stop
    /// again, and never keeps the next message from going out (#517).
    @MainActor
    func testGroupStopAgainAfterALostStopAnswer() {
        for appearance in ["light", "dark"] { checkGroupStopAgain(appearance: appearance) }
    }

    @MainActor
    private func checkGroupStopAgain(appearance: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-team-call",
                               "-preview-group-stop-lost", "-loopdy.home.landing", "bots",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        openGroupFromBots(titled: "Weekend planners", in: app)
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))

        composer.tap()
        composer.typeText("Any ideas for Saturday?")
        app.buttons["chat.send"].tap()
        let stop = app.buttons["chat.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        let again = app.buttons["chat.bot-mode.stop-again"]
        XCTAssertTrue(again.waitForExistence(timeout: 10), "The lost stop leaves Stop again")
        XCTAssertTrue(app.staticTexts["Hermes did not confirm the stop."].exists)
        let unconfirmed = XCTAttachment(screenshot: app.screenshot())
        unconfirmed.name = "group-stop-unconfirmed-\(appearance)"
        unconfirmed.lifetime = .keepAlways
        add(unconfirmed)

        again.tap()
        XCTAssertTrue(again.waitForNonExistence(timeout: 10), "Stop again settles the stop")
        composer.tap()
        composer.typeText("One idea each, please")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let answer = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND label CONTAINS %@", "keep an eye on the budget"
        )).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 15), "The next message goes out and the room answers")
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "group-stop-recovered-\(appearance)"
        recovered.lifetime = .keepAlways
        add(recovered)
        app.terminate()
    }
}
