import XCTest

/// Settings › System on a synthetic host (`-test-system-page`), laid out like Fleet settings:
/// update Hermes, the gateway's restart, and Additional settings folded away until opened.
/// BIGHELP_SYSTEM_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class SystemPageUITests: BighelpUITestCase {
    @MainActor
    func testUpdateAndRestartUpTopTheRestInAdditionalSettings() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-test-system-page", "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["system.hermes.update"].waitForExistence(timeout: 15), "Update Hermes up top")
            let additional = app.descendants(matching: .any)["system.additional"].firstMatch
            let list = app.collectionViews.firstMatch
            for _ in 0..<4 where !(additional.exists && additional.isHittable) { list.swipeUp() }
            XCTAssertTrue(additional.exists, "Additional settings")
            XCTAssertFalse(app.buttons["Raw Configuration"].exists, "Folded away at first")
            save("system-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }
            additional.tap()
            let raw = app.buttons["Raw Configuration"]
            for _ in 0..<4 where !(raw.exists && raw.isHittable) { list.swipeUp() }
            XCTAssertTrue(raw.waitForExistence(timeout: 5), "The advanced pages are inside")
            save("system-additional", app)
            app.terminate()
        }
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SYSTEM_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
