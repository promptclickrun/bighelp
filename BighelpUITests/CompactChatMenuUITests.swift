import XCTest

/// Fixture-only layout and navigation checks; no live host or paid turns.
final class CompactChatMenuUITests: BighelpUITestCase {
    @MainActor
    func testHomeOpensCanonicalBotChatInsteadOfTheNewerOrdinaryConversation() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-canonical-agent-chat",
                               "-loopdy.home.opens-chat", "YES"]
        app.launch()
        let canonical = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "This is the shared Bot Chat.")).firstMatch
        XCTAssertTrue(canonical.waitForExistence(timeout: 20), "Home must open the canonical chat, not the newer ordinary one")
        chatNewChatButton(in: app).tap()
        confirmNewChatPicker(in: app)
        XCTAssertTrue(canonical.waitForNonExistence(timeout: 8), "Explicit New chat still starts an ordinary conversation")
    }

    @MainActor
    func testCompactMenuAndFastModeInLightDarkAndLargeText() {
        for (appearance, large) in [("light", false), ("dark", true)] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-v3-header-context", "-test-fast-mode", "-loopdy.demo.appearance", appearance]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            let options = app.buttons["chat.options"].firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 20))
            options.tap()
            evidence("compact-menu-\(appearance)")
            let rootRows = large
                ? ["chat.options.model-speed", "chat.options.this-chat", "chat.options.more"]
                : ["chat.file-changes", "chat.options.model-speed", "chat.options.this-chat", "chat.options.usage", "chat.options.advanced"]
            for title in rootRows {
                let row = app.buttons[title].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), title)
                XCTAssertTrue(row.isHittable, "\(title) must be reachable without scrolling")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(row.frame), "\(title) must fit on screen")
            }
            app.buttons["chat.options.model-speed"].tap()
            let fast = app.buttons["chat.fast-mode"].firstMatch
            XCTAssertTrue(fast.waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["chat.session-controls"].isHittable)
            fast.tap()
            let on = app.buttons["chat.fast-mode.on"].firstMatch
            XCTAssertTrue(on.waitForExistence(timeout: 8))
            XCTAssertTrue(on.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(on.frame), "The cost notice must fit, too")
            evidence("fast-mode-\(appearance)")
            on.tap()
            let reopened = chatMenuItem("chat.fast-mode", in: app)
            XCTAssertTrue(reopened.waitForExistence(timeout: 5))
            XCTAssertTrue(reopened.label.contains("On"), "The saved chat value is visible")
            // Demo chats have no native session, so Session tools and Force
            // refresh are absent. More and This chat still exercise full rows.
            let submenus = large ? [
                ["chat.options.settings", "chat.files", "chat.edit-current-agent"],
                ["chat.rename", "chat.appearance"],
                ["chat.file-changes", "chat.options.usage", "chat.options.advanced"],
                ["chat.provider-usage", "chat.context-window"],
                ["chat.options.display"],
                ["chat.visibility.reasoning", "chat.visibility.tool-calls"]
            ] : [
                ["chat.rename", "chat.files", "chat.appearance", "chat.edit-current-agent"],
                ["chat.provider-usage", "chat.context-window"],
                ["chat.visibility.reasoning", "chat.visibility.tool-calls"]
            ]
            for identifiers in submenus {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)).tap()
                _ = chatMenuItem(identifiers[0], in: app)
                evidence("submenu-\(identifiers[0])-\(appearance)")
                for identifier in identifiers {
                    let item = app.buttons[identifier].firstMatch
                    XCTAssertTrue(item.exists && item.isHittable, "\(identifier) must not need scrolling")
                    if item.exists { XCTAssertTrue(app.windows.firstMatch.frame.contains(item.frame)) }
                }
            }
            app.terminate()
        }
    }

    @MainActor
    func testDefaultFastModeShowsTheSavedValueOnTheModelsPage() {
        let app = makeApp()
        app.launchArguments = ["-test-models-page", "-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        let row = app.buttons["agent.runtime.mainChats.fast-mode"].firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        for _ in 0..<4 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.isEnabled)
        row.tap()
        let on = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "On")).firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 5))
        on.tap()
        XCTAssertTrue(waitForElement(row, predicate: NSPredicate(format: "label CONTAINS %@", "On")))
        evidence("default-fast-mode")
        row.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.tap()
        XCTAssertTrue(waitForElement(row, predicate: NSPredicate(format: "label CONTAINS %@", "Off")))
    }

    @MainActor
    private func waitForElement(_ element: XCUIElement, predicate: NSPredicate) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    @MainActor
    private func evidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
