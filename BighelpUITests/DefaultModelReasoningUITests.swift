import XCTest

/// Default model › Reasoning on the synthetic Models page (`-test-models-page`): one control sets
/// every agent's reasoning, or just the picked agent's. BIGHELP_REASONING_EVIDENCE (TEST_RUNNER_…)
/// saves the screenshots.
final class DefaultModelReasoningUITests: BighelpUITestCase {
    @MainActor
    func testReasoningChangesForEveryAgentOrOne() throws {
        let app = makeApp()
        app.launchArguments = ["-test-models-page"]
        app.launch()
        let reasoning = app.buttons["models.reasoning"].firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        for _ in 0..<4 where !(reasoning.exists && reasoning.isHittable) { list.swipeUp() }
        XCTAssertTrue(reasoning.waitForExistence(timeout: 10), "Default model has Reasoning")
        XCTAssertTrue(app.buttons["models.reasoning.scope"].firstMatch.exists, "Every agent, or just this one")
        save("reasoning", app)
        reasoning.tap()
        let high = app.buttons["High"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 5))
        high.tap()
        let saved = app.descendants(matching: .any)["models.reasoning.saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue(saved.label.contains("every agent"), saved.label)
        save("reasoning-saved", app)
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_REASONING_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
