import XCTest

/// Shipping-shell simplification: four destinations, one contextual compose action.
final class SimplifiedShellUITests: BighelpUITestCase {
    @MainActor
    func testMentionsStayInsideTheirMessageInLightAppearance() {
        verifyInlineMentions(appearance: "light")
    }

    @MainActor
    func testMentionsStayInsideTheirMessageInDarkAppearance() {
        verifyInlineMentions(appearance: "dark")
    }

    @MainActor
    private func verifyInlineMentions(appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-inline-mentions",
                               "-loopdy.home.opens-chat", "NO", "-loopdy.demo.appearance", appearance]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let human = app.textViews.matching(NSPredicate(format: "label == %@",
            "You: Before Avery Park, ask All about the plan; then Avery Park can review it. After.")).firstMatch
        let agent = app.textViews.matching(NSPredicate(format: "label == %@",
            "Avery Park: Ask Jordan Lee for a second opinion. Code stays plain: @all.")).firstMatch
        XCTAssertTrue(human.waitForExistence(timeout: 5))
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertTrue(human.isHittable)
        XCTAssertTrue(agent.isHittable)
        capture("chat-inline-mentions-\(appearance)", in: app)
        human.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy to clipboard"].waitForExistence(timeout: 3))
        app.buttons["Copy to clipboard"].tap()
        XCTAssertTrue(human.exists)
        let input = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        input.tap()
        input.typeText("Please ask @avery-park and @all to review this.")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()
        let sent = app.textViews.matching(NSPredicate(format: "label ENDSWITH %@",
            "Please ask Avery Park and All to review this.")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        capture("chat-inline-mentions-sent-\(appearance)", in: app)
    }

    @MainActor
    func testWideAssistantRepliesInDarkAppearance() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
                               "-loopdy.demo.appearance", "dark"]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let header = app.otherElements["chat.header-surface"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let reply = app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", "high-level itinerary")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        if header.frame.width < 600 {
            XCTAssertGreaterThanOrEqual(reply.frame.width, header.frame.width * 0.78)
            XCTAssertLessThanOrEqual(reply.frame.minX, header.frame.minX + 32)
        }
        XCTAssertTrue(reply.isHittable)
        capture("chat-wide-replies-dark", in: app)
    }

    @MainActor
    func testAgentsClearUsesNativeHitTargetAndDismissesKeyboard() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openRootTab("tab.agents", in: app, timeout: 10)
        let search = app.textFields["agents.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("zzzz-no-agent")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No matching agents"].waitForExistence(timeout: 3))
        let clear = app.buttons["agents.search.clear"]
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThanOrEqual(clear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(clear.frame.height, 44)
        capture("agents-clear-native-target", in: app)
        clear.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "Search agents and groups")
        XCTAssertTrue(app.buttons["agent.finance"].exists)
        capture("agents-clear-dismissed-keyboard", in: app)
    }

    @MainActor
    func testAgentsDestinationSearchGroupsAndDrawerOrder() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-agent-groups",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openRootTab("tab.agents", in: app, timeout: 10)
        XCTAssertTrue(app.textFields["agents.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["agents.group.demo-agent-group"].exists)
        XCTAssertFalse(app.buttons["agents.group.open-chat"].exists)
        capture("agents-groups", in: app)
        app.textFields["agents.search"].tap()
        app.textFields["agents.search"].typeText("zzzz-no-agent")
        XCTAssertTrue(app.staticTexts["No matching agents"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["agents.group.demo-agent-group"].exists)
        capture("agents-search-before-clear", in: app)
        app.buttons["agents.search.clear"].tap()
        capture("agents-search-after-clear", in: app)
        XCTAssertTrue(app.buttons["agents.group.demo-agent-group"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.exists)
        menu.tap()
        let agents = app.buttons["menu.agents"]
        let tasks = app.buttons["menu.scheduled-tasks"]
        let settings = app.buttons["menu.settings"]
        for row in [agents, tasks, settings] { XCTAssertTrue(row.isHittable) }
        XCTAssertLessThan(agents.frame.maxY, tasks.frame.midY)
        XCTAssertLessThan(tasks.frame.maxY, settings.frame.midY)
        XCTAssertFalse(app.buttons["menu.hermes-tools"].exists, "Hermes tools live in Settings.")
        XCTAssertFalse(app.buttons["quick-workspace.menu.scratchpad"].exists)
        XCTAssertFalse(app.buttons["quick-workspace.wiki"].exists)
        XCTAssertTrue(app.buttons["menu.new-chat"].exists)
        capture("drawer-agents-and-tools", in: app)
        agents.tap()
        XCTAssertTrue(app.textFields["agents.search"].waitForExistence(timeout: 3))
        app.buttons["agents.group.demo-agent-group"].tap()
        XCTAssertTrue(app.otherElements["chat.header-surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
    }

    @MainActor
    func testAgentCanStartANewChatFromItsActions() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openRootTab("tab.agents", in: app, timeout: 10)
        let search = app.textFields["agents.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Jordan")
        let agent = app.buttons["agent.home"]
        XCTAssertTrue(agent.waitForExistence(timeout: 3))
        agent.tap() // XCTest scrolls this specific row into view above the keyboard.
        let newChat = app.buttons["agent.home.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(app.otherElements["chat.header-surface"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
    }

    @MainActor
    func testDeviceAccessOverviewKeepsConsentInEachCapability() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        XCTAssertTrue(app.staticTexts["Choose what to share."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["permissions.device-tools.calendar"].exists)
        let calendar = app.buttons["permissions.open.calendar"]
        XCTAssertTrue(calendar.exists)
        calendar.tap()
        let toggle = app.switches["permissions.device-tools.calendar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(app.alerts.count, 0)
        capture("device-access-calendar", in: app)
    }

    @MainActor
    func testAppPermissionDetailsRequireAnExplicitAllowAction() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.permissions", in: app).tap()
        XCTAssertFalse(app.buttons["permissions.notification.allow"].exists)
        let notifications = app.buttons["permissions.open.notification"]
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        XCTAssertTrue(app.buttons["permissions.notification.allow"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        capture("notification-permission-details", in: app)
    }

    @MainActor
    func testChatMatchesUnclutteredReferenceAndDisclosesComposerControls() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat", "-loopdy.demo.appearance", "light"]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let header = app.otherElements["chat.header-surface"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let brand = chatIdentity(in: app)
        XCTAssertEqual(brand.frame.midX, header.frame.midX, accuracy: 3)
        XCTAssertTrue(header.frame.insetBy(dx: -1, dy: -1).contains(brand.frame))
        let sidebar = app.otherElements["quick-workspace.persistent-sidebar"]
        if sidebar.exists {
            XCTAssertLessThanOrEqual(sidebar.frame.maxX, header.frame.minX)
        } else {
            XCTAssertEqual(header.frame.midX, app.frame.midX, accuracy: 3)
        }
        let geometry = XCTAttachment(string: "App: \(app.frame)\nHeader: \(header.frame)\nBrand: \(brand.frame)\nSidebar: \(sidebar.exists ? String(describing: sidebar.frame) : "absent")")
        geometry.name = "chat-header-pane-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
        XCTAssertFalse(header.staticTexts["AI agents for a brighter you"].exists)
        XCTAssertFalse(app.buttons["chat.message.actions"].exists)
        XCTAssertFalse(app.buttons["chat.session-controls"].exists)
        let reply = app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", "high-level itinerary")
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        if header.frame.width < 600 {
            XCTAssertGreaterThanOrEqual(reply.frame.width, header.frame.width * 0.78,
                "Assistant prose must use the phone's width instead of a narrow column.")
            XCTAssertLessThanOrEqual(reply.frame.minX, header.frame.minX + 32)
        }
        capture("chat-simple-idle", in: app)
        let editor = app.textViews["chat.composer.text"]
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["chat.session-controls"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat.session-context"].exists, "The context window lives in the ⋯ menu")
        XCTAssertTrue(app.otherElements["chat.composer-shell"].buttons["chat.session-controls"].exists)
        editor.typeText("Add lunch")
        let draftArrived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (editor.value as? String)?.contains("Add lunch") == true
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [draftArrived], timeout: 3), .completed)
        capture("chat-simple-editing", in: app)
        app.buttons["chat.session-controls"].tap()
        let modelPicker = app.descendants(matching: .any)["model-picker.surface"].firstMatch
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["model-picker.selection-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["model-picker.reasoning-slider"].firstMatch.exists)
        capture("chat-model-sheet", in: app)
        app.buttons["model-picker.dismiss"].tap()
        XCTAssertTrue(modelPicker.waitForNonExistence(timeout: 3))
        editor.tap()
        XCTAssertTrue((editor.value as? String)?.contains("Add lunch") == true)
        // The context window opens from the chat's ⋯ menu and keeps the draft.
        let context = openContextWindow(in: app)
        XCTAssertTrue(app.staticTexts["Context window"].waitForExistence(timeout: 3))
        capture("chat-context-sheet", in: app)
        XCTAssertTrue(context.exists)
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if outside.exists && outside.isHittable {
            outside.tap()
        } else {
            context.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(context.waitForNonExistence(timeout: 3))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue((editor.value as? String)?.contains("Add lunch") == true)
        capture("chat-context-dismissed-draft-retained", in: app)
    }

    @MainActor
    func testFocusedComposerAtAccessibilitySizeKeepsControlsReachable() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
            "-loopdy.demo.appearance", "dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let chat = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        let composer = app.otherElements["chat.composer-shell"]
        for identifier in ["chat.attachment", "chat.session-controls", "chat.voice"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists, identifier)
            XCTAssertTrue(button.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, identifier)
            XCTAssertTrue(composer.frame.insetBy(dx: -1, dy: -1).contains(button.frame), identifier)
        }
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
        capture("chat-accessibility-editing", in: app)
    }

    @MainActor
    func testEverydayNavigationHasFiveAgentDestinationsAndKeepsNewChatReachable() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.appearance.interface-version", "v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 10))
        let baseline = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        baseline.name = "simplified-shell-intake"
        baseline.lifetime = .keepAlways
        add(baseline)
        // Chat, Feed, Ideas, Goals and Apps; Agents, Tasks and Settings live in ☰.
        let expectedLabels = [
            "tab.sessions": "Chat", "tab.feed": "Feed", "tab.ideas": "Ideas",
            "tab.goals": "Goals", "tab.apps": "Apps",
        ]
        for (identifier, label) in expectedLabels {
            XCTAssertTrue(app.buttons[identifier].isHittable, identifier)
            XCTAssertEqual(app.buttons[identifier].label, label)
        }
        for retired in ["tab.agents", "tab.scheduled-tasks", "tab.profile"] {
            XCTAssertFalse(app.buttons[retired].exists, retired)
        }
        XCTAssertTrue(app.buttons["home.drawer.open"].isHittable)
        let compose = app.buttons["root.new-chat"]
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        guard compose.exists else { return }
        XCTAssertGreaterThanOrEqual(compose.frame.width, 44)
        XCTAssertGreaterThanOrEqual(compose.frame.height, 44)
        compose.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.composer.text"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
    }

    @MainActor
    func testModelControlLivesInsideFocusedComposer() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 10))
        app.buttons["tab.sessions"].tap()
        let compose = app.buttons["shell.new-chat"]
        if compose.exists { compose.tap() } else { app.buttons["root.new-chat"].tap() }
        let editor = app.descendants(matching: .any)["chat.composer.text"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let header = app.otherElements["chat.header-surface"]
        XCTAssertTrue(chatIdentity(in: app).exists, "The header should identify who this conversation is with.")
        XCTAssertFalse(header.buttons["chat.session-controls"].exists,
                       "Runtime knobs must not replace the conversation identity in the header.")
        editor.tap()
        let controls = app.buttons["chat.session-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["chat.composer-shell"].buttons["chat.session-controls"].exists)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "conversation-hierarchy"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testActivityPutsRequestsBeforeInformationalUpdates() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light"]
        app.launch()
        openActivity(in: app)
        let attention = app.buttons["dashboard.attention.row.attention-payment"]
        let update = app.buttons["dashboard.update.row.inbox-finance-payment"]
        XCTAssertTrue(attention.waitForExistence(timeout: 10))
        XCTAssertTrue(update.exists)
        XCTAssertLessThan(attention.frame.minY, update.frame.minY,
                          "A request for your decision takes precedence over an informational update.")
        XCTAssertEqual(app.staticTexts["loopdy.root.title"].label, "Activity")
        capture("activity", in: app)
    }

    @MainActor
    func testSettingsIsACompactIndexWithoutExplanationsUnderEveryRow() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light"]
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your private on-device bighelp profile"].exists)
        XCTAssertFalse(app.staticTexts["Profile, bighelp Link, and paired devices"].exists)
        XCTAssertFalse(app.staticTexts["Reasoning, tool calls, inline UI, and voice"].exists)
        capture("you", in: app)
        let appearance = settingsRow("settings.menu.appearance", in: app)
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testConnectStartsWithAddressAndDisclosesAdvancedOptions() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
        app.launch()
        XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["host-setup.discover"].exists,
                       "The initial connection step needs one primary action, not Check and Connect.")
        XCTAssertFalse(app.textFields["host-setup.port"].exists)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "connect-simple"
        before.lifetime = .keepAlways
        add(before)
        // The disclosure is an accessibility container so field IDs remain distinct.
        let options = app.buttons["More options"].firstMatch
        XCTAssertTrue(options.exists)
        guard options.exists else { return }
        options.tap()
        XCTAssertTrue(app.textFields["host-setup.port"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["host-setup.name"].exists)
        XCTAssertFalse(app.switches["direct-hermes.private-http"].exists, "HTTP on a private network is found, not switched on")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "connect-options"
        after.lifetime = .keepAlways
        add(after)
    }
    @MainActor
    func testDarkMainScreensAndConversationStayReachable() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 10))
        for (tab, screen) in [("sessions", "sessions.screen"), ("home", "dashboard.screen"), ("profile", "settings.screen")] {
            app.buttons["tab.\(tab)"].tap()
            let content = app.descendants(matching: .any)[screen].firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 5))
            XCTAssertTrue(content.isHittable)
            capture("dark-\(tab)", in: app)
        }
        app.buttons["tab.sessions"].tap()
        app.buttons["shell.new-chat"].tap()
        XCTAssertTrue(chatIdentity(in: app).waitForExistence(timeout: 5))
        app.textViews["chat.composer.text"].tap()
        XCTAssertTrue(app.buttons["chat.session-controls"].waitForExistence(timeout: 3))
        capture("dark-conversation", in: app)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
