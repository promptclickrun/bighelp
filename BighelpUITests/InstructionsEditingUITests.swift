import XCTest

/// Editing a bot's instructions on demo data with a long SOUL (`-test-long-soul`, about 6,000
/// characters): a bot page's Instructions sheet. Set BIGHELP_INSTRUCTIONS_EVIDENCE (TEST_RUNNER_…) to a
/// folder to save the screenshots.
final class InstructionsEditingUITests: BighelpUITestCase {
    @MainActor
    func testBotPageInstructionsSheet() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-long-soul",
                                   "-loopdy.home.landing", "bots", "-loopdy.demo.appearance", appearance]
            app.launch()
            let primary = app.buttons["simple-bots.primary"]
            XCTAssertTrue(primary.waitForExistence(timeout: 15))
            primary.tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            // The demo chat is still settling right after it opens; a tap then can land before the
            // header takes it.
            let profile = app.descendants(matching: .any)["simple-bots.profile"]
            identity.tap()
            if !profile.waitForExistence(timeout: 3) { identity.tap() }
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            app.buttons["simple-bots.profile.tab.info"].tap()
            let row = app.buttons["simple-bots.profile.instructions"]
            for _ in 0..<4 where !row.isHittable { app.swipeUp() }
            row.tap()
            let editor = app.textViews["simple-bots.instructions.editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            let saveButton = app.buttons["simple-bots.instructions.save"]
            XCTAssertFalse(saveButton.isEnabled, "Nothing to save yet")
            editor.tap()
            editor.typeText(" Keep receipts.")
            XCTAssertTrue(saveButton.isEnabled)
            save("instructions-bots-\(appearance)", app)
            // Unsaved instructions stay through a swipe down.
            app.navigationBars["Instructions"].swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertTrue(editor.exists && saveButton.isHittable, "A swipe down keeps the unsaved instructions")
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_INSTRUCTIONS_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
