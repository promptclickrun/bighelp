import XCTest

/// The chat's ⋯ menu, top to bottom: Go to…, File changes, Model & reasoning
/// (showing the current model), the context window, provider usage, this chat (rename, files,
/// appearance), the agent, then Advanced with Session tools. No People & Chat.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ChatOptionsMenuUITests: BighelpUITestCase {
    @MainActor
    func testMenuIsOrderedByHowOftenEachIsNeeded() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-enable-project-changes", "-use-project-changes-markdown-fixture",
                                   "-test-v3-header-context", "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 15))
            let first = chatMenuItem("chat.workspace-menu", in: app)
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            let order = ["chat.workspace-menu", "chat.file-changes", "chat.session-controls", "chat.context-window",
                         "chat.provider-usage", "chat.rename",
                         "chat.files", "chat.appearance", "chat.edit-current-agent", "chat.options.advanced"]
            let items = order.map { app.buttons[$0].firstMatch }
            for (identifier, item) in zip(order, items) {
                XCTAssertTrue(item.exists, "\(identifier) is in the menu")
            }
            for (upper, lower) in zip(items, items.dropFirst()) where upper.exists && lower.exists {
                XCTAssertLessThan(upper.frame.midY, lower.frame.midY,
                                  "\(upper.identifier) comes before \(lower.identifier)")
            }
            XCTAssertFalse(app.buttons["chat.open-people"].exists, "People & Chat left the menu")
            XCTAssertTrue(app.buttons["chat.file-changes"].label.contains("file"), app.buttons["chat.file-changes"].label)
            evidence("menu-\(appearance)")

            app.buttons["chat.options.advanced"].tap()
            // Session tools need a live Hermes session, which demo chats don't have.
            let reasoning = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Show reasoning")).firstMatch
            XCTAssertTrue(reasoning.waitForExistence(timeout: 5), "Advanced opens")
            evidence("advanced-\(appearance)")
            app.terminate()
        }
    }

    /// Without Nerd Mode the menu is just the everyday items.
    @MainActor
    func testEverydayMenuWithoutNerdMode() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].firstMatch.waitForExistence(timeout: 15))
        let model = chatMenuItem("chat.session-controls", in: app)
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        for hidden in ["chat.workspace-menu", "chat.file-changes", "chat.context-window", "chat.options.advanced",
                       "chat.open-people"] {
            XCTAssertFalse(app.buttons[hidden].exists, "\(hidden) is for Nerd Mode or gone")
        }
        for shown in ["chat.rename", "chat.files", "chat.appearance", "chat.edit-current-agent"] {
            XCTAssertTrue(app.buttons[shown].exists, "\(shown) is an everyday item")
        }
        evidence("menu-everyday")
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-options-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-options-\(name).png"))
    }
}
