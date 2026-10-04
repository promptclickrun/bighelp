import XCTest

/// Agents › New agent › avatar: the Characters grid, and Face's colors like Shapes'. BIGHELP_AVATAR_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class AvatarCreatorUITests: BighelpUITestCase {
    @MainActor
    func testFacesHaveColorsLikeShapes() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openRootTab("tab.agents", in: app)
        let create = app.buttons["agents.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let preview = app.descendants(matching: .any)["agent.editor.avatar-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["avatar.creator.style.face"].firstMatch.waitForExistence(timeout: 10))
        save("characters", app)
        any["avatar.creator.style.face"].firstMatch.tap()
        let swatch = any["avatar.creator.face-color.3"].firstMatch
        for _ in 0..<5 where !(swatch.exists && swatch.isHittable) { app.swipeUp() }
        XCTAssertTrue(swatch.exists, "Face has colors like Shapes")
        swatch.tap()
        let saturation = any["avatar.creator.face-color.saturation"].firstMatch
        for _ in 0..<3 where !(saturation.exists && saturation.isHittable) { app.swipeUp() }
        XCTAssertTrue(saturation.exists, "Saturation, down to gray")
        saturation.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(any["avatar.creator.face-color.custom"].firstMatch.exists, "The color wheel")
        save("face-color", app)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
