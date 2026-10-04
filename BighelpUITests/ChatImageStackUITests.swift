import XCTest

/// Several pictures in one message show as a stack (`-test-image-stack`): you sent two, the agent
/// four. Opening the agent's stack swipes through them, the strip jumps to one, and Save and Share
/// offer this photo or all of them. Set BIGHELP_IMAGE_STACK_EVIDENCE (TEST_RUNNER_…) to a folder
/// to save the screenshots.
final class ChatImageStackUITests: BighelpUITestCase {
    @MainActor
    func testAStackOfPicturesOpensToSwipeSaveAndShare() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-image-stack", "-loopdy.demo.appearance", appearance]
            app.launch()
            let stacks = app.descendants(matching: .any).matching(identifier: "chat.image-stack")
            XCTAssertTrue(stacks.firstMatch.waitForExistence(timeout: 15), "Several pictures show as a stack")
            XCTAssertEqual(stacks.count, 2, "Yours and the agent's")
            let agentStack = stacks.matching(NSPredicate(format: "label == %@", "4 photos")).firstMatch
            XCTAssertTrue(agentStack.exists)
            XCTAssertTrue(stacks.matching(NSPredicate(format: "label == %@", "2 photos")).firstMatch.exists)
            save("image-stack-chat-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }

            agentStack.tap()
            XCTAssertTrue(app.navigationBars["1 of 4"].waitForExistence(timeout: 5), "Opens on the first")
            app.buttons["chat.image-stack.thumbnail.2"].tap()
            XCTAssertTrue(app.navigationBars["3 of 4"].waitForExistence(timeout: 5), "The strip jumps to one")
            app.descendants(matching: .any)["chat.image-stack.pages"].firstMatch.swipeLeft()
            XCTAssertTrue(app.navigationBars["4 of 4"].waitForExistence(timeout: 5), "Swiping goes to the next")
            save("image-stack-viewer", app)

            app.buttons["chat.image-stack.save"].tap()
            XCTAssertTrue(app.buttons["Save All 4 Photos"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Save This Photo"].exists)
            save("image-stack-save-menu", app)
            app.buttons["Save This Photo"].tap()
            app.buttons["chat.image-stack.share"].tap()
            XCTAssertTrue(app.buttons["Share All 4 Photos"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Share This Photo"].exists)
            app.terminate()
        }
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_IMAGE_STACK_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
