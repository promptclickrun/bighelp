import XCTest

/// Long-press › Share… on demo data: the sheet previews the message in each
/// format, and the preview changes with the format.
final class ChatShareUITests: BighelpUITestCase {
    @MainActor
    func testShareShowsTheMessageInEachFormat() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()

        let agentMessage = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@",
            "chat.message.inline-selection", "Avery Park: Room for the conversation")).firstMatch
        XCTAssertTrue(agentMessage.waitForExistence(timeout: 8))
        agentMessage.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)
        let share = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Share…")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 3), "Share… is in the message menu")
        share.tap()

        let sheet = app.descendants(matching: .any)["chat.share.sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        // The last pick is remembered (not pinned here, so taps can change it); start on Messages.
        app.buttons["Messages"].firstMatch.tap()
        let preview = app.textViews["chat.share.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        let styled = waitForPreview(preview, toContain: "𝗥𝗼𝗼𝗺")
        XCTAssertTrue(styled.contains("𝗥𝗼𝗼𝗺"), "Messages shows styled bold letters: \(styled)")
        XCTAssertFalse(styled.contains("**"), styled)
        XCTAssertTrue(app.staticTexts["Some apps and screen readers can't read styled letters."].exists)
        XCTAssertTrue(app.buttons["chat.share.copy"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chat.share.share"].firstMatch.exists)

        app.buttons["Markdown"].firstMatch.tap()
        let markdown = waitForPreview(preview, toContain: "**Room")
        XCTAssertTrue(markdown.contains("**Room for the conversation.**"), markdown)
        XCTAssertFalse(app.staticTexts["Some apps and screen readers can't read styled letters."].exists)

        app.buttons["Plain text"].firstMatch.tap()
        let plain = waitForPreview(preview, toContain: "Room for the conversation.")
        XCTAssertFalse(plain.contains("**"), plain)
        XCTAssertFalse(plain.contains("𝗥"), plain)

        app.buttons["PDF"].firstMatch.tap()
        XCTAssertTrue(app.images["chat.share.preview"].waitForExistence(timeout: 5), "PDF shows its first page")

        app.buttons["chat.share.copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2), "Copy confirms in place")
    }

    @MainActor
    private func waitForPreview(_ preview: XCUIElement, toContain text: String) -> String {
        let deadline = Date().addingTimeInterval(3)
        var value = ""
        repeat {
            value = preview.value as? String ?? ""
            if value.contains(text) { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return value
    }
}
