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
                ? ["chat.options.model-speed", "chat.options.this-chat", "chat.options.agent", "chat.options.more"]
                : ["chat.options.model-speed", "chat.rename", "chat.move-project", "chat.files", "chat.edit-current-agent",
                   "chat.options.usage", "chat.file-changes", "chat.options.advanced"]
            for title in rootRows {
                let row = chatMenuElement(title, in: app)
                XCTAssertTrue(row.waitForExistence(timeout: 5), title)
                XCTAssertTrue(row.isHittable, "\(title) must be reachable without scrolling")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(row.frame), "\(title) must fit on screen")
            }
            chatMenuElement("chat.options.model-speed", in: app).tap()
            let fast = chatMenuElement("chat.fast-mode", in: app)
            XCTAssertTrue(fast.waitForExistence(timeout: 8))
            XCTAssertTrue(chatMenuElement("chat.session-controls", in: app).isHittable)
            fast.tap()
            let on = chatMenuElement("chat.fast-mode.on", in: app)
            XCTAssertTrue(on.waitForExistence(timeout: 8))
            XCTAssertTrue(on.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(on.frame), "The cost notice must fit, too")
            evidence("fast-mode-\(appearance)")
            on.tap()
            let reopened = chatMenuItem("chat.fast-mode", in: app)
            XCTAssertTrue(reopened.waitForExistence(timeout: 5))
            XCTAssertTrue(reopened.label.contains("On"), "The saved chat value is visible")
            // Demo chats have no native session, so Force refresh is absent.
            // More and This chat still exercise full rows.
            let submenus = large ? [
                ["chat.rename", "chat.move-project", "chat.files"],
                ["chat.switch-agent", "chat.edit-current-agent"],
                ["chat.file-changes", "chat.options.usage", "chat.options.advanced"],
                ["chat.provider-usage", "chat.context-window", "chat.compact"],
                ["chat.options.display"],
                ["chat.visibility.reasoning", "chat.visibility.tool-calls"]
            ] : [
                ["chat.provider-usage", "chat.context-window", "chat.compact"],
                ["chat.visibility.reasoning", "chat.visibility.tool-calls"]
            ]
            for identifiers in submenus {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.55)).tap()
                _ = chatMenuItem(identifiers[0], in: app)
                evidence("submenu-\(identifiers[0])-\(appearance)")
                for identifier in identifiers {
                    let item = chatMenuElement(identifier, in: app)
                    XCTAssertTrue(item.exists && item.isHittable, "\(identifier) must not need scrolling")
                    if item.exists { XCTAssertTrue(app.windows.firstMatch.frame.contains(item.frame)) }
                }
            }
            app.terminate()
        }
    }

    /// The ⋯ menu doesn't depend on Nerd Mode: File changes, Advanced and Context window
    /// show with it off, and Compact works.
    @MainActor
    func testEveryMenuItemShowsWithNerdModeOff() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-v3-header-context", "-loopdy.settings.nerd-mode", "NO"]
        app.launch()
        let options = app.buttons["chat.options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        options.tap()
        for identifier in ["chat.file-changes", "chat.options.advanced", "chat.move-project"] {
            XCTAssertTrue(chatMenuElement(identifier, in: app).waitForExistence(timeout: 5), identifier)
        }
        let usage = chatMenuElement("chat.options.usage", in: app)
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        let contextWindow = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@", "chat.context-window", "Context window")).firstMatch
        XCTAssertTrue(contextWindow.waitForExistence(timeout: 5), "Context window without Nerd Mode")
        let compact = chatMenuElement("chat.compact", in: app)
        XCTAssertTrue(compact.waitForExistence(timeout: 5), "Usage has Compact without Nerd Mode")
        evidence("usage-nerd-off")
        compact.tap()
        let running = app.descendants(matching: .any)["chat.compaction.running"].firstMatch
        XCTAssertTrue(running.waitForExistence(timeout: 15), "Compact works without Nerd Mode")
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
