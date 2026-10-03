import XCTest

/// The Models page, its auxiliary tasks and Mixture of Agents all use the chat's
/// model picker. Set BIGHELP_MODEL_SETTINGS_EVIDENCE
/// (TEST_RUNNER_BIGHELP_MODEL_SETTINGS_EVIDENCE) to save screenshots.
final class ModelSettingsPickerUITests: BighelpUITestCase {
    @MainActor
    func testModelsPageUsesTheChatModelPicker() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-models-page"]
        app.launch()

        // The default model: the shared picker, then save.
        let main = app.buttons["models.main"]
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        save("01-models-page", app)
        main.tap()
        let surface = app.descendants(matching: .any)["model-picker.surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertTrue(app.searchFields["Search providers and models"].exists)
        let anthropic = app.buttons["model-picker.provider.anthropic"]
        XCTAssertTrue(anthropic.exists)
        anthropic.tap()
        let sonnet = app.buttons["model-picker.anthropic.claude-sonnet-5"]
        XCTAssertTrue(sonnet.waitForExistence(timeout: 3))
        sonnet.tap()
        let apply = app.buttons["model-picker.apply"]
        XCTAssertEqual(apply.label, "Save as default")
        save("02-default-model-picker", app)
        apply.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        XCTAssertTrue((main.value as? String)?.contains("Sonnet 5") == true, String(describing: main.value))

        // Auxiliary task: same picker.
        let compression = app.buttons["models.auxiliary.compression"]
        for _ in 0..<6 where !compression.isHittable { app.swipeUp() }
        XCTAssertTrue(compression.isHittable)
        save("03-auxiliary-tasks", app)
        compression.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["model-picker.apply"].label, "Save for this task")
        save("04-auxiliary-picker", app)
        app.buttons["model-picker.dismiss"].tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))

        // Mixture of Agents slots: same picker.
        let moa = app.buttons["Edit model assignments"]
        for _ in 0..<6 where !moa.isHittable { app.swipeUp() }
        moa.tap()
        let reference = app.buttons["Reference 1"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap()
        let slot = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Change")).firstMatch
        XCTAssertTrue(slot.waitForExistence(timeout: 3))
        save("05-moa", app)
        slot.tap()
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["model-picker.apply"].label, "Use this model")
        save("06-moa-picker", app)
        app.buttons["model-picker.dismiss"].tap()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MODEL_SETTINGS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
