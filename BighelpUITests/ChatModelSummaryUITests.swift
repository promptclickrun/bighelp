import XCTest

/// During a chat you can see its model and reasoning without opening a picker:
/// in the avatar's profile, the context pop-up and the ⋯ menu. Each opens Model &
/// reasoning. Set BIGHELP_MODEL_SUMMARY_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class ChatModelSummaryUITests: BighelpUITestCase {
    @MainActor
    func testAvatarProfileShowsThisChatsModelAndChangesIt() {
        let app = launch(appearance: "light")
        let avatar = app.buttons["agent.hero.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agent.profile"].firstMatch.waitForExistence(timeout: 5))
        let summary = app.buttons["chat.model-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The profile says what this chat runs on")
        XCTAssertTrue(summary.label.contains("Model:"), summary.label)
        XCTAssertTrue(summary.label.contains("Reasoning:"), summary.label)
        save("01-profile-model", app)

        summary.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.session-controls.popover"].firstMatch
            .waitForExistence(timeout: 8), "Change opens Model & reasoning for this chat")
        save("02-profile-change", app)
    }

    @MainActor
    func testContextPopUpShowsTheModelFirst() {
        let app = launch(appearance: "dark")
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 10))
        let popover = openContextWindow(in: app)
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        let summary = app.buttons["chat.model-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The context pop-up leads with the model")
        XCTAssertTrue(summary.label.contains("Reasoning:"), summary.label)
        XCTAssertTrue(popover.frame.contains(summary.frame))
        save("03-context-model", app)

        summary.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.session-controls.popover"].firstMatch
            .waitForExistence(timeout: 8))
    }

    @MainActor
    func testChatMenuShowsTheModelUnderModelAndReasoning() {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 10))
        let model = chatMenuItem("chat.session-controls", in: app)
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(model.isHittable, "Model & reasoning is near the top of the menu")
        XCTAssertTrue(model.label.contains("Model & reasoning"), model.label)
        XCTAssertTrue(model.label.contains("·"), "It says which model and reasoning: \(model.label)")
        save("04-menu-model", app)
        model.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.session-controls.popover"].firstMatch
            .waitForExistence(timeout: 8))
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-v3-header-context", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MODEL_SUMMARY_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
