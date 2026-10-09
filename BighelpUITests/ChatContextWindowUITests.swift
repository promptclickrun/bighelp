import XCTest

/// The context window opens from the chat's ⋯ › Usage submenu,
/// as the same pop-up the ring above the message box used
/// to open. Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ChatContextWindowUITests: BighelpUITestCase {
    @MainActor
    func testContextWindowOpensFromTheChatMenu() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            XCTAssertFalse(app.buttons["chat.session-context"].exists, "No context button above the message box")

            let item = chatMenuItem("chat.context-window", in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "⋯ has Context window")
            let order = ["chat.provider-usage", "chat.context-window"].map {
                app.buttons[$0].firstMatch
            }
            for element in order { XCTAssertTrue(element.exists, element.identifier) }
            for (upper, lower) in zip(order, order.dropFirst()) {
                XCTAssertLessThan(upper.frame.midY, lower.frame.midY,
                                  "\(upper.identifier) comes before \(lower.identifier)")
            }
            evidence("menu-\(appearance)")

            item.tap()
            let popover = app.descendants(matching: .any)["chat.session-context.popover"].firstMatch
            XCTAssertTrue(popover.waitForExistence(timeout: 5), "The context pop-up opens")
            XCTAssertTrue(app.staticTexts["Context window"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["chat.session-context.latest-input"].exists, "Token rows")
            XCTAssertTrue(app.buttons["chat.model-summary"].exists, "The pop-up leads with the model")
            evidence("popover-\(appearance)")

            // Its provider usage button closes the pop-up and opens usage.
            app.buttons["chat.session-context.provider-usage"].tap()
            XCTAssertTrue(popover.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["provider-usage"].firstMatch.waitForExistence(timeout: 8),
                          "Provider usage opens from the pop-up")
            app.terminate()
        }
    }

    /// Without Nerd Mode the token readout stays out of the menu, as the ring did.
    @MainActor
    func testEverydayMenuHasNoContextWindow() {
        let app = launch(appearance: "light", extra: ["-loopdy.settings.nerd-mode", "NO"])
        let model = chatMenuItem("chat.session-controls", in: app)
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.context-window"].exists)
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-v3-header-context", "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-context-window-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("chat-context-window-\(name).png"))
    }
}
