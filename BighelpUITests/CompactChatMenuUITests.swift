import XCTest

/// Fixture-only layout and navigation checks; no live host or paid turns.
final class CompactChatMenuUITests: BighelpUITestCase {
    @MainActor
    func testABotOpensItsCanonicalBotChatInsteadOfTheNewerOrdinaryConversation() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-canonical-agent-chat",
                               "-loopdy.home.landing", "bots"]
        app.launch()
        let primary = app.buttons["simple-bots.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 20))
        primary.tap()
        let canonical = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "This is the shared Bot Chat.")).firstMatch
        XCTAssertTrue(canonical.waitForExistence(timeout: 20), "The bot must open the canonical chat, not the newer ordinary one")
        chatNewChatButton(in: app).tap()
        confirmNewChatPicker(in: app, botID: "finance")
        XCTAssertTrue(canonical.waitForNonExistence(timeout: 8), "Explicit New chat still starts an ordinary conversation")
    }

    @MainActor
    func testCompactMenuAndFastModeInLightDarkAndLargeText() {
        // The whole list, File changes and all, at the default size; from XL the menu folds into This
        // chat, Agent and More, and at accessibility sizes Advanced also folds its switches into Display.
        for (appearance, size) in [("light", nil), ("light", "UICTContentSizeCategoryXL"),
                                   ("dark", "UICTContentSizeCategoryAccessibilityXXXL")] {
            let accessibility = size?.contains("Accessibility") == true
            let large = size != nil
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-v3-header-context", "-test-fast-mode", "-loopdy.demo.appearance", appearance]
            if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
            app.launch()
            let options = app.buttons["chat.options"].firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 20))
            options.tap()
            evidence("compact-menu-\(appearance)-\(size ?? "default")")
            let rootRows = large
                ? ["chat.options.model-speed", "chat.options.this-chat", "chat.options.agent", "chat.options.more"]
                : ["chat.rename", "chat.move-project", "chat.files", "chat.file-changes",
                   "chat.options.model-speed", "chat.options.usage", "chat.bot-page", "chat.options.advanced"]
            for title in rootRows {
                let row = chatMenuElement(title, in: app)
                let at = size ?? "the default size"
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(title) at \(at)")
                XCTAssertTrue(row.isHittable, "\(title) must be reachable without scrolling at \(at)")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(row.frame), "\(title) must fit on screen at \(at)")
            }
            // The largest accessibility size still scrolls these four rows, as before the list was regrouped.
            if !accessibility { assertMenuDoesNotScroll(app, at: size ?? "the default size") }
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
                ["chat.bot-page"],
                ["chat.file-changes", "chat.options.usage", "chat.options.advanced"],
                ["chat.provider-usage", "chat.context-window", "chat.compact"]
            ] + (accessibility ? [["chat.options.display"]] : []) + [
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
                if !accessibility { assertMenuDoesNotScroll(app, at: "\(size ?? "the default size") in \(identifiers[0])'s menu") }
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

    /// Models › Default model (`-test-models-page`): each bot's row names its model and opens its own
    /// Default Model page, where Fast and the rest are set.
    @MainActor
    func testModelsPageOpensEachBotsDefaultModel() {
        let app = makeApp()
        app.launchArguments = ["-test-models-page", "-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        let row = app.buttons["models.bot.travel"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForElement(row, predicate: NSPredicate(format: "label CONTAINS %@", "Mina Shah, ")),
                      "The row names the bot and its model: \(row.label)")
        evidence("models-default-model")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["default-models"].firstMatch.waitForExistence(timeout: 10),
                      "The bot's own Default Model page")
    }

    /// A row cut off at the bottom still counts as hittable, so check the menu itself: one taller than
    /// iOS lets it be gets a scroll bar of more than one page.
    @MainActor
    private func assertMenuDoesNotScroll(_ app: XCUIApplication, at size: String) {
        let bars = app.collectionViews.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar"))
        for bar in bars.allElementsBoundByIndex where !bar.label.hasSuffix(" 1 page") {
            XCTFail("The menu scrolls at \(size): \(bar.label)")
        }
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
