import XCTest

/// "Go to the chat that is working": touch and hold on the Dynamic Island, and on the iPhone Duo's
/// cover screen the pill at the top of a chat's side column. Demo data with a turn that really runs
/// (`-test-tool-stream`), never a forced activity. Runs on a phone with an island and on the Duo's
/// simulator; each uses the way in that its screen has.
final class WorkingChatUITests: BighelpUITestCase {
    /// One bot, two chats. Its work in the chat that isn't open must stay one step away. The way
    /// there once compared bots, not chats, so from another chat of the same bot it did nothing.
    @MainActor
    func testWorkInAnotherChatOfTheSameBotOpensThatChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-start-chat",
                               "-test-tool-stream", "-test-tool-stream-hold", "90",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        defer { app.terminate() }

        // Avery starts work in one chat.
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Avery's chat opens")
        input.tap()
        input.typeText("Check the March budget")
        app.buttons["chat.send"].tap()
        let sent = app.textViews["You: Check the March budget"]
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "The message is in the chat")

        // Another chat with Avery, from the list.
        app.buttons["chat.back"].firstMatch.tap()
        let other = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "demo-session-3")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), "The list has another chat with Avery")
        other.tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(chatIdentity(in: app).label, "Avery Park", "The other chat is Avery's too")
        XCTAssertTrue(sent.waitForNonExistence(timeout: 10), "It is another chat")

        // The work shows where this screen says who is working, and leads to the chat it is in.
        let island = app.descendants(matching: .any)["agent.island"].firstMatch
        let pill = app.buttons["chat.working-elsewhere"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !island.exists, !pill.exists { usleep(300_000) }
        if pill.exists {
            XCTAssertTrue(pill.label.hasPrefix("Avery Park"), pill.label)
            pill.tap()
        } else {
            XCTAssertTrue(island.exists, "The island or the Duo's column says Avery is working")
            XCTAssertTrue(island.label.hasPrefix("Avery Park"), island.label)
            // A tap beside the camera opens the big stage. That it grows shows touches reach the
            // island here, so a hold that then goes nowhere is the app's doing, not the test's.
            let compact = island.frame.height
            island.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            let grown = Date().addingTimeInterval(5)
            while Date() < grown, island.frame.height < compact + 20 { usleep(200_000) }
            XCTAssertGreaterThan(island.frame.height, compact + 20, "A tap opens the island's stage")
            // Touch and hold on the stage, under the camera.
            island.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 1.0)
        }
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "The chat where Avery works opens")
        XCTAssertEqual(chatIdentity(in: app).label, "Avery Park")
    }
}
