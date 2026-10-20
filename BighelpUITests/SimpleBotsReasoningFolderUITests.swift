import XCTest

/// Simple Bot mode's "{Agent}'s reasoning" folder: open while the bot works, closed in place when the
/// turn ends, and a tap opens it again (demo tool stream: two notes, each before a tool, then the answer).
final class SimpleBotsReasoningFolderUITests: BighelpUITestCase {
    @MainActor
    func testReasoningFolderClosesWhenTheTurnEnds() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance,
                                   "-loopdy.chat.showReasoningByDefault", "YES",
                                   "-test-tool-stream", "-test-tool-stream-two-turns", "-test-tool-stream-slow"]
            app.launch()
            XCTAssertTrue(app.buttons["simple-bots.primary"].waitForExistence(timeout: 15))
            app.buttons["simple-bots.primary"].tap()
            let input = app.textViews["chat.composer.text"]
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap()
            input.typeText("Check the source")
            app.buttons["chat.send"].tap()

            let folder = app.buttons["chat.reasoning.header"]
            XCTAssertTrue(folder.waitForExistence(timeout: 10), "The bot's reasoning folder")
            let note = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", "Investigation step 1", "Investigation step 1")).firstMatch
            XCTAssertTrue(note.waitForExistence(timeout: 5), "Open while the bot works")
            XCTAssertEqual(folder.value as? String, "Expanded")
            save("reasoning-live-\(appearance)", app)

            let answer = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@", "TOOL STREAM COMPLETE", "TOOL STREAM COMPLETE")).firstMatch
            XCTAssertTrue(answer.waitForExistence(timeout: 30), "The answer")
            XCTAssertTrue(note.waitForNonExistence(timeout: 5), "Closed in place when the turn ends")
            XCTAssertTrue(folder.exists, "The same folder stays")
            XCTAssertEqual(folder.value as? String, "Collapsed")
            // The answer is long; the folder sits above it, where the notes were.
            for _ in 0..<6 where !folder.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            }
            save("reasoning-done-\(appearance)", app)

            folder.tap()
            XCTAssertTrue(note.waitForExistence(timeout: 5), "A tap opens it again")
            XCTAssertEqual(folder.value as? String, "Expanded")
            save("reasoning-reopened-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
