import XCTest

/// Settings › Appearance › Thinking on demo data: every look can be tried, the buttons on top set
/// them all to one level, and the look picked there is the one a chat's Model settings shows.
/// Set BIGHELP_THINKING_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class ThinkingLookUITests: BighelpUITestCase {
    @MainActor
    func testPickingALookAndTryingIt() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
            app.launch()
            openSettings(in: app)
            settingsRow("settings.themes", in: app).tap()
            let studio = app.descendants(matching: .any)["appearance.studio"].firstMatch
            XCTAssertTrue(studio.waitForExistence(timeout: 5))
            let thinking = app.buttons["settings.appearance.thinking"].firstMatch
            for _ in 0..<8 where !thinking.exists || !thinking.isHittable { studio.swipeUp() }
            thinking.tap()

            // Noodle is the look out of the box (the pass before puts it back).
            let noodle = app.buttons["thinking-look.pick.noodle"]
            XCTAssertTrue(noodle.waitForExistence(timeout: 5))
            XCTAssertTrue(noodle.isSelected)
            save("thinking-high-\(appearance)", app)

            // The buttons on top put every look on one level.
            let first = app.descendants(matching: .any)["thinking-look.try.noodle"].firstMatch
            XCTAssertEqual(first.value as? String, "High")
            app.buttons["thinking-look.set-all.ultra"].tap()
            XCTAssertEqual(first.value as? String, "Ultra")
            save("thinking-ultra-\(appearance)", app)

            // A drag tries one look and changes nothing else.
            let start = first.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)))
            XCTAssertEqual(first.value as? String, "Off")
            let second = app.descendants(matching: .any)["thinking-look.try.trainOfThought"].firstMatch
            XCTAssertEqual(second.value as? String, "Ultra")

            // The name line picks the look.
            let page = app.descendants(matching: .any)["thinking-look"].firstMatch
            let clockwork = app.buttons["thinking-look.pick.clockwork"]
            for _ in 0..<6 where !clockwork.exists || !clockwork.isHittable { page.swipeUp() }
            clockwork.tap()
            XCTAssertTrue(clockwork.isSelected)
            XCTAssertFalse(noodle.isSelected)
            save("thinking-picked-\(appearance)", app)

            // The pick is kept on the device, so the next pass starts from Noodle again.
            for _ in 0..<6 where !noodle.isHittable { page.swipeDown() }
            noodle.tap()
            XCTAssertTrue(noodle.isSelected)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_THINKING_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
