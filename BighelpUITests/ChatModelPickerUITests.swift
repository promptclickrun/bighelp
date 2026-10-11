import XCTest

/// The chat's Model & reasoning sheet on demo data: the reasoning slider picks a
/// level by dragging, and the choice waits for Apply. Set BIGHELP_MODEL_PICKER_EVIDENCE
/// (TEST_RUNNER_…) to save screenshots.
final class ChatModelPickerUITests: BighelpUITestCase {
    @MainActor
    func testReasoningSliderPicksALevel() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            openModelAndReasoning(in: app)
            let slider = app.descendants(matching: .any)["chat.reasoning-slider"].firstMatch
            XCTAssertTrue(slider.waitForExistence(timeout: 10))
            let apply = app.buttons["chat.session-controls.apply"]
            XCTAssertFalse(apply.isEnabled, "Nothing to apply yet")

            // Drag the thumb from the left end to the middle level.
            let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.42))
            start.press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)))
            XCTAssertEqual(slider.value as? String, "Medium")
            XCTAssertTrue(apply.isEnabled, "A new level waits for Apply")
            save("reasoning-medium-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MODEL_PICKER_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}

extension BighelpUITestCase {
    /// ⋯ › Model & reasoning in a chat.
    @MainActor
    func openModelAndReasoning(in app: XCUIApplication) {
        _ = chatMenuItem("chat.session-controls", in: app, timeout: 2)
        // Native menu rows can expose their title instead of their SwiftUI identifier.
        let controls = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@", "chat.session-controls", "Model & reasoning"
        )).firstMatch
        if !controls.waitForExistence(timeout: 2) {
            // The first tap can arrive while the native submenu is still laying out.
            let group = app.buttons["chat.options.model-speed"].firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(controls.waitForExistence(timeout: 8))
        controls.tap()
    }
}
