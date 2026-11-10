import XCTest

/// The chat's Model settings sheet on demo data: the model chip in the message box opens it, a drag
/// on the Thinking control picks a level at once (there is no Apply), and All models folds by
/// provider. Set BIGHELP_MODEL_PICKER_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class ChatModelPickerUITests: BighelpUITestCase {
    @MainActor
    func testThinkingControlPicksALevelAtOnce() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openModelSettings(in: app)
            let thinking = app.descendants(matching: .any)["chat.thinking"].firstMatch
            XCTAssertTrue(thinking.waitForExistence(timeout: 10))
            XCTAssertEqual(thinking.value as? String, "Auto", "The demo chat starts on Hermes' automatic level")
            save("model-settings-\(appearance)", app)

            // Drag along the track from its left end to the second of the demo's four levels.
            let start = thinking.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: thinking.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.5)))
            XCTAssertEqual(thinking.value as? String, "Medium")
            save("thinking-medium-\(appearance)", app)

            // It was sent when the finger lifted: closing and opening again shows the same level.
            app.buttons["chat.model-settings.done"].firstMatch.tap()
            XCTAssertTrue(thinking.waitForNonExistence(timeout: 5))
            openModelSettings(in: app)
            XCTAssertTrue(thinking.waitForExistence(timeout: 10))
            XCTAssertEqual(thinking.value as? String, "Medium")
            app.terminate()
        }
    }

    @MainActor
    func testAllModelsFoldsByProviderAndPicksAModel() {
        let app = launch(appearance: "light")
        openModelSettings(in: app)
        let current = app.buttons["chat.model-settings.model"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(current.label.contains("Hermes"), current.label)
        current.tap()

        // The chat's own provider starts unfolded, the others folded.
        XCTAssertTrue(app.buttons["chat.models.row.nous:Hermes-4-70B"].waitForExistence(timeout: 10))
        let other = app.buttons["chat.models.row.openai:gpt-5.6"]
        XCTAssertFalse(other.exists)
        save("all-models", app)
        app.buttons["chat.models.section.openai"].tap()
        XCTAssertTrue(other.waitForExistence(timeout: 5))

        // A star keeps a model on top.
        app.buttons["chat.models.star.openai:gpt-5.6"].tap()
        XCTAssertTrue(app.buttons["chat.models.section.starred"].waitForExistence(timeout: 5))

        // A tap picks the model for the chat and goes back to the short sheet.
        other.firstMatch.tap()
        XCTAssertTrue(app.buttons["chat.models.section.openai"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.localizedCaseInsensitiveContains("GPT-5.6"), current.label)
        save("model-picked", app)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
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
    /// The model chip in a chat's message box: opens Model settings.
    @MainActor
    func openModelSettings(in app: XCUIApplication) {
        let chip = app.buttons["chat.composer.model"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: chip)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "The chip is on while no answer is streaming")
        chip.tap()
        XCTAssertTrue(app.buttons["chat.model-settings.model"].waitForExistence(timeout: 10))
    }
}
