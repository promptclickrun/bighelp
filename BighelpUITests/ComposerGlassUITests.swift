import XCTest

/// The message box, + and voice button in glass over a chat's pictures (`-test-image-stack`),
/// in light and dark. BIGHELP_COMPOSER_GLASS_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class ComposerGlassUITests: BighelpUITestCase {
    @MainActor
    func testComposerReadsOverTheChat() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-image-stack", "-loopdy.demo.appearance", appearance]
            app.launch()
            let composer = app.textViews["chat.composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["chat.attachment"].exists)
            XCTAssertTrue(app.buttons["chat.voice"].exists)
            save("composer-\(appearance)", app)
            app.terminate()
        }
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_COMPOSER_GLASS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
