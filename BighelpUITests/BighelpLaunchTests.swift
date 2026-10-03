import XCTest
import UIKit
import CoreFoundation

final class BighelpLaunchTests: BighelpUITestCase {
    @MainActor
    func testSettingsOmitsRetiredAccountAndDeviceMenu() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        openSettings(in: app)
        for _ in 0..<4 {
            XCTAssertFalse(app.buttons["settings.menu.accountAndDevices"].exists)
            app.swipeUp()
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "settings-without-legacy-account"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testNotificationSettingsKeepsDiagnosticsOutOfPrimaryScreen() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        openSettings(in: app)
        let notifications = settingsRow("settings.menu.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        for index in 0..<4 {
            XCTAssertFalse(app.staticTexts["Delivery Provider"].exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Configured, identified, registered, provider-ready")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "iOS controls alerts, sounds, badges")).firstMatch.exists)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "concise-notifications-\(index)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.swipeUp()
        }
    }

    /// Turn off notifications asks first, shows plain progress, then a plain
    /// result. Demo mode leaves Studio Mac out of reach to show that message.
    /// Set BIGHELP_TURN_OFF_EVIDENCE (TEST_RUNNER_…) to keep screenshots.
    @MainActor
    func testTurnOffNotificationsAsksFirstAndReportsPlainly() throws {
        for appearance in ["light", "dark"] {
            try turnOffNotifications(appearance: appearance)
        }
    }

    @MainActor
    private func turnOffNotifications(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-preview-ui-v3", "-demo-turn-off-offline-host",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        openSettings(in: app)
        let notifications = settingsRow("settings.menu.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        let turnOff = app.buttons["settings.notifications.turn-off"]
        for _ in 0..<6 where !(turnOff.exists && turnOff.isHittable) { app.swipeUp() }
        XCTAssertTrue(turnOff.isHittable, "Turn Off Notifications is on the Notifications screen")
        saveTurnOff("1-button-\(appearance)")

        turnOff.tap()
        let confirm = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Turn Off Notifications", "settings.notifications.turn-off"
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "It asks before deleting anything")
        saveTurnOff("2-confirm-\(appearance)")
        confirm.tap()

        let progress = app.descendants(matching: .any)["settings.notifications.turn-off.progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "Plain progress while it works")
        saveTurnOff("3-progress-\(appearance)")

        let result = app.descendants(matching: .any)["settings.notifications.turn-off.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        XCTAssertTrue(result.label.hasPrefix("Notifications are off."), result.label)
        XCTAssertTrue(result.label.contains("Studio Mac"), "An unreachable computer is named: \(result.label)")
        XCTAssertFalse(turnOff.exists, "Nothing left to turn off")
        saveTurnOff("4-result-\(appearance)")
        app.terminate()
    }

    @MainActor
    private func saveTurnOff(_ name: String) {
        guard ProcessInfo.processInfo.environment["BIGHELP_TURN_OFF_EVIDENCE"] != nil else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "turn-off-notifications-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testChatsHeaderClearsMenuAndOpensDrawerOnFirstTap() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for variant in ["portrait", "landscape", "large-text"] {
            XCUIDevice.shared.orientation = variant == "landscape" ? .landscapeLeft : .portrait
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
            if variant == "large-text" {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            let chats = app.buttons["tab.sessions"]
            XCTAssertTrue(chats.waitForExistence(timeout: 10))
            chats.tap()
            let title = app.staticTexts.matching(identifier: "loopdy.root.title")
                .matching(NSPredicate(format: "label == %@", "Chats")).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let menu = app.buttons["home.drawer.open"]
            XCTAssertTrue(menu.isHittable)
            XCTAssertFalse(menu.frame.intersects(title.frame))
            XCTAssertLessThanOrEqual(menu.frame.maxY, title.frame.minY)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "chats-header-\(variant)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            menu.tap()
            XCTAssertTrue(app.buttons["menu.settings"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testNotificationsSettingsOpensAndShowsSystemAndTopicControls() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()
        openSettings(in: app)
        let notifications = settingsRow("settings.menu.notifications", in: app)
        XCTAssertTrue(notifications.waitForExistence(timeout: 5))
        notifications.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "BuzzKit")).firstMatch.exists,
                       "The normal notification screen must not expose provider implementation copy")
        let topic = app.descendants(matching: .any)["settings.notifications.topic.chat-replies-completions"]
        for _ in 0..<5 where !topic.isHittable { app.swipeUp() }
        XCTAssertTrue(topic.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "buzzkit-notification-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testOpeningHomeWithCompletedHistoryAndQueuedDeliveryRemainsResponsive() throws {
        let app = makeApp()
        let signal = "app.loopdy.fixture.idle.\(UUID().uuidString)"
        let replayed = XCTestExpectation(description: "Historical delivery completed while idle")
        let observer = Unmanaged.passRetained(replayed).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<XCTestExpectation>.fromOpaque(observer).takeUnretainedValue().fulfill()
        }, signal as CFString, nil, .deliverImmediately)
        defer {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(signal as CFString), nil)
            Unmanaged<XCTestExpectation>.fromOpaque(observer).release()
        }
        app.launchEnvironment["BIGHELP_IDLE_REPLAY_COMPLETION_NOTIFICATION"] = signal
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-idle-replay"]
        app.launch()
        XCTAssertEqual(XCTWaiter.wait(for: [replayed], timeout: 30), .completed)
        let report = app.staticTexts["fixture.idle-replay-metrics"]
        XCTAssertTrue(report.waitForExistence(timeout: 3))
        let text = report.label
        let attachment = XCTAttachment(string: text)
        attachment.name = "idle-replay-main-thread-metrics"
        attachment.lifetime = .keepAlways
        add(attachment)
        func metric(_ key: String) throws -> Int {
            let regex = try NSRegularExpression(pattern: key + #"=(\d+)"#)
            let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
            return try XCTUnwrap(Int(String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])))
        }
        XCTAssertEqual(try metric("ACTIVE_SESSIONS"), 0)
        XCTAssertEqual(try metric("CATALOG_WRITES"), 1)
        XCTAssertGreaterThan(try metric("FRAME_COUNT"), 60)
        XCTAssertLessThan(try metric("MAIN_QUEUE_MAX_MS"), 250)
        XCTAssertLessThan(try metric("FRAME_GAP_MS"), 500)
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(settingsRow("settings.menu.chat", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testVoiceSettingsEditsProviderKeyAndVoiceWithConfirmedSave() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-voice-settings-fixture"]
        app.launch()
        openSettings(in: app)
        let voiceSettings = settingsRow("settings.chat.voice-settings", in: app)
        XCTAssertTrue(voiceSettings.waitForExistence(timeout: 3))
        guard voiceSettings.exists else { return }
        voiceSettings.tap()
        // The speech provider belongs to TTS voice mode.
        let voiceMode = app.segmentedControls["voice.settings.conversation-mode"]
        XCTAssertTrue(voiceMode.waitForExistence(timeout: 3))
        voiceMode.buttons["TTS"].tap()
        let provider = app.buttons["voice.settings.provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        provider.tap()
        let elevenLabs = app.buttons["voice.provider.elevenlabs"]
        for _ in 0..<4 where !(elevenLabs.exists && elevenLabs.isHittable) { app.swipeUp() }
        elevenLabs.tap()
        let voice = app.textFields["voice.settings.voice-id"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        voice.tap()
        voice.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
            count: (voice.value as? String ?? "").count))
        voice.typeText("fixture-eleven-voice")
        let apiKey = app.secureTextFields["voice.settings.api-key"]
        XCTAssertTrue(apiKey.exists)
        apiKey.tap()
        apiKey.typeText("fixture-provider-key")
        let save = app.buttons["voice.settings.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(waitForSavedVoiceSettings(save))
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "voice.settings.save").count, 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "voice-settings-confirmed-save"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        for _ in 0..<4 where !provider.isHittable { app.swipeDown() }
        provider.tap()
        let openAI = app.buttons["voice.provider.openai"]
        for _ in 0..<4 where !(openAI.exists && openAI.isHittable) { app.swipeUp() }
        openAI.tap()
        voice.tap()
        voice.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
            count: (voice.value as? String ?? "").count))
        voice.typeText("coral")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(waitForSavedVoiceSettings(save))
        XCTAssertFalse(save.isEnabled)
        app.navigationBars["Voice"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(voiceSettings.waitForExistence(timeout: 3))
        voiceSettings.tap()
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        XCTAssertEqual(voice.value as? String, "coral")
        let keyStatus = app.staticTexts["API key saved on your computer"]
        for _ in 0..<3 where !keyStatus.exists { app.swipeUp() }
        XCTAssertTrue(keyStatus.exists)
        XCTAssertFalse(app.buttons["voice.settings.save"].isEnabled)
    }

    /// The Save button reads "Saved" once the host confirms, wherever the page is scrolled.
    @MainActor
    func waitForSavedVoiceSettings(_ save: XCUIElement) -> Bool {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Saved'"), object: save)
        return XCTWaiter().wait(for: [saved], timeout: 5) == .completed
    }

    @MainActor
    func testQuickWorkspaceCompactNavigationKeepsMenusAndPreviewRowsVisible() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()

        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()

        let drawer = app.descendants(matching: .any)["navigation.menu"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))

        let menuIDs = [
            "menu.agents",
            "menu.scheduled-tasks",
            "menu.settings",
        ]
        let menuRows = menuIDs.map { app.buttons[$0].firstMatch }
        for row in menuRows {
            XCTAssertTrue(row.waitForExistence(timeout: 3), row.identifier)
            XCTAssertTrue(row.isHittable, "\(row.identifier) must be visible without scrolling")
            XCTAssertGreaterThanOrEqual(row.frame.height, 43.5, row.identifier)
            XCTAssertLessThanOrEqual(row.frame.maxY, drawer.frame.maxY + 1, row.identifier)
        }
        for (first, second) in zip(menuRows, menuRows.dropFirst()) {
            XCTAssertLessThan(first.frame.minY, second.frame.minY, "Menu routes must retain their visible order")
        }

        let pinnedAgent = app.buttons["menu.agent.finance"]
        let recentSession = app.buttons["menu.chat.demo-finance"]
        XCTAssertTrue(pinnedAgent.waitForExistence(timeout: 3))
        XCTAssertTrue(recentSession.waitForExistence(timeout: 3))
        XCTAssertTrue(pinnedAgent.isHittable, "A pinned agent preview should be visible below the menu routes")
        XCTAssertTrue(recentSession.isHittable, "A recent session preview should be visible below pinned agents")
        XCTAssertGreaterThanOrEqual(pinnedAgent.frame.height, 43.5)
        XCTAssertGreaterThanOrEqual(recentSession.frame.height, 43.5)
        XCTAssertLessThan(
            menuRows[5].frame.maxY,
            pinnedAgent.frame.minY,
            "The last navigation route must remain above pinned-agent previews"
        )
        XCTAssertLessThan(
            pinnedAgent.frame.maxY,
            recentSession.frame.minY,
            "Pinned-agent previews must remain above recent sessions"
        )

        let drawerShot = XCTAttachment(screenshot: app.screenshot())
        drawerShot.name = "quick-workspace-compact-initial"
        drawerShot.lifetime = .keepAlways
        add(drawerShot)

        menuRows[3].tap()
        let scheduledScreen = app.descendants(matching: .any)["scheduled-tasks.screen"]
        XCTAssertTrue(
            scheduledScreen.waitForExistence(timeout: 5),
            "The visible Scheduled Tasks route must perform real navigation"
        )
        let scheduledShot = XCTAttachment(screenshot: app.screenshot())
        scheduledShot.name = "quick-workspace-scheduled-tasks-route"
        scheduledShot.lifetime = .keepAlways
        add(scheduledShot)

        let routeMenu = app.buttons["workspace.menu"]
        let createScheduledTask = app.buttons["scheduled-tasks.create"]
        XCTAssertTrue(routeMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(routeMenu.isHittable, "The routed workspace menu must remain hittable")
        XCTAssertTrue(createScheduledTask.waitForExistence(timeout: 3))
        XCTAssertTrue(createScheduledTask.isHittable, "The scheduled-task create action must remain hittable")
        createScheduledTask.tap()
        XCTAssertTrue(
            app.buttons["scheduled-task.editor.weekday.monday"].waitForExistence(timeout: 5),
            "Scheduled Tasks plus must open the real task editor"
        )
    }

    @MainActor
    func testQuickWorkspaceCapsPinnedPreviewAndOpensAllAgentsRoute() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3"]
        app.launch()

        openRootTab("tab.agents", in: app, timeout: 5)
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].waitForExistence(timeout: 5))

        for agentID in ["travel", "home"] {
            let row = app.buttons["agent.\(agentID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing fixture agent \(agentID)")
            app.buttons["agent.\(agentID).more"].tap()

            let pin = app.buttons["agent.\(agentID).pin"]
            XCTAssertTrue(pin.waitForExistence(timeout: 3), "Missing pin action for \(agentID)")
            XCTAssertTrue(pin.isEnabled, "Fixture agent \(agentID) should be pinnable")
            if pin.label.contains("Unpin") {
                pin.tap()
                XCTAssertTrue(pin.waitForNonExistence(timeout: 3), "Unpinning \(agentID) should dismiss the action sheet")
                app.buttons["agent.\(agentID).more"].tap()
                XCTAssertTrue(pin.waitForExistence(timeout: 3), "Pin action should be available again for \(agentID)")
            }
            pin.tap()
            XCTAssertTrue(pin.waitForNonExistence(timeout: 3), "Pinning \(agentID) should dismiss the action sheet")
        }

        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()

        let firstPreview = app.buttons["menu.agent.finance"]
        let secondPreview = app.buttons["menu.agent.travel"]
        let boundedOut = app.buttons["menu.agent.home"]
        let allAgents = app.buttons["quick-workspace.agents.more"]
        let session = app.buttons["menu.chat.demo-finance"]
        XCTAssertTrue(firstPreview.waitForExistence(timeout: 3))
        XCTAssertTrue(secondPreview.waitForExistence(timeout: 3))
        XCTAssertFalse(boundedOut.exists, "The third pinned agent must remain behind the full Agents route")
        XCTAssertTrue(allAgents.waitForExistence(timeout: 3))
        XCTAssertTrue(allAgents.isHittable, "The full Agents affordance must remain reachable")
        XCTAssertTrue(allAgents.label.contains("See all 3 pinned agents"))
        XCTAssertTrue(session.waitForExistence(timeout: 3))
        XCTAssertTrue(session.isHittable, "Sessions must remain visible with three pinned agents")

        allAgents.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["navigation.menu"].exists)
    }

    @MainActor
    func testSessionProjectCollapseIsSharedWithSidebar() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-preview-ui-v3", "-loopdy.sessions.organizeByProjects", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        let toggle = app.buttons["sessions.section-toggle.project:demo-loopdy"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Projects need an actual collapse button")
        guard toggle.exists else { return }
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44, "Collapse needs a full-size touch target")
        if toggle.value as? String == "Collapsed" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "Expanded")
        let sessionRow = app.descendants(matching: .any).matching(identifier: "session.row.demo-finance").firstMatch
        XCTAssertTrue(sessionRow.exists, "Expanded project must expose its actual session row")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        XCTAssertFalse(sessionRow.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "sessions-project-collapsed"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["home.drawer.open"].tap()
        let drawerToggle = app.buttons["quick-workspace.section-toggle.project:demo-loopdy"]
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(drawerToggle.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["menu.chat.demo-finance"].exists)
        drawerToggle.tap()
        XCTAssertEqual(drawerToggle.value as? String, "Expanded")
        XCTAssertTrue(app.buttons["menu.chat.demo-finance"].exists)
        let drawerShot = XCTAttachment(screenshot: app.screenshot())
        drawerShot.name = "sidebar-project-expanded"
        drawerShot.lifetime = .keepAlways
        add(drawerShot)
        app.buttons["menu.done"].tap()
        XCTAssertEqual(toggle.value as? String, "Expanded")
    }

    @MainActor
    func testProjectDragOrderingAndCollapsePersistAcrossViewsAndRelaunch() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-preview-ui-v3", "-loopdy.sessions.organizeByProjects", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        let bighelpKey = "project:demo-loopdy"
        let travelKey = "project:demo-travel"
        func toggle(_ prefix: String, _ key: String) -> XCUIElement {
            app.buttons["\(prefix).section-toggle.\(key)"]
        }
        func collapse(_ prefix: String, _ key: String) {
            let control = toggle(prefix, key)
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            if control.value as? String == "Expanded" { control.tap() }
            XCTAssertEqual(control.value as? String, "Collapsed")
        }
        func moveFirstBelowSecond(_ prefix: String) -> (String, String) {
            let a = toggle(prefix, bighelpKey)
            let b = toggle(prefix, travelKey)
            let first = a.frame.minY < b.frame.minY ? bighelpKey : travelKey
            let second = first == bighelpKey ? travelKey : bighelpKey
            let handle = app.buttons["\(prefix).section-reorder.\(first)"]
            XCTAssertTrue(handle.exists)
            let destination = toggle(prefix, second)
            handle.press(forDuration: 0.8, thenDragTo: destination)
            let reordered = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in toggle(prefix, first).frame.minY > toggle(prefix, second).frame.minY },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 3), .completed)
            return (second, first)
        }
        collapse("sessions", bighelpKey)
        collapse("sessions", travelKey)
        let firstOrder = moveFirstBelowSecond("sessions")
        try saveSessionOrganizationEvidence(app, name: "sessions-reordered-collapsed")
        app.buttons["home.drawer.open"].tap()
        XCTAssertTrue(toggle("quick-workspace", bighelpKey).waitForExistence(timeout: 3))
        XCTAssertLessThan(toggle("quick-workspace", firstOrder.0).frame.minY,
                          toggle("quick-workspace", firstOrder.1).frame.minY)
        XCTAssertEqual(toggle("quick-workspace", bighelpKey).value as? String, "Collapsed")
        let secondOrder = moveFirstBelowSecond("quick-workspace")
        try saveSessionOrganizationEvidence(app, name: "sidebar-reordered-collapsed")
        app.buttons["menu.done"].tap()
        XCTAssertLessThan(toggle("sessions", secondOrder.0).frame.minY,
                          toggle("sessions", secondOrder.1).frame.minY)
        app.buttons["sessions.section-reorder.\(secondOrder.1)"].tap()
        let moveUp = app.buttons.matching(NSPredicate(format: "label == %@", "Move Up")).firstMatch
        XCTAssertTrue(moveUp.waitForExistence(timeout: 3))
        moveUp.tap()
        let persistedOrder = (secondOrder.1, secondOrder.0)
        XCTAssertLessThan(toggle("sessions", persistedOrder.0).frame.minY,
                          toggle("sessions", persistedOrder.1).frame.minY)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(toggle("sessions", persistedOrder.0).waitForExistence(timeout: 3))
        XCTAssertLessThan(toggle("sessions", persistedOrder.0).frame.minY,
                          toggle("sessions", persistedOrder.1).frame.minY)
        XCTAssertEqual(toggle("sessions", bighelpKey).value as? String, "Collapsed")
        XCTAssertEqual(toggle("sessions", travelKey).value as? String, "Collapsed")
        // Restore expanded sections for subsequent fixture interactions.
        toggle("sessions", bighelpKey).tap()
        toggle("sessions", travelKey).tap()
        try saveSessionOrganizationEvidence(app, name: "sessions-restored-expanded")
    }

    @MainActor
    func testActiveChatsPrecedePinsOnBothSurfaces() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-test-session-organization", "-loopdy.sessions.organizeByProjects", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.staticTexts["Active Chats"].firstMatch.waitForExistence(timeout: 3))
        // old-pin is also active, so it belongs above the idle new-pin.
        let ids = ["old-pin", "old-active", "new-active", "new-pin"]
        let rows = ids.map { app.descendants(matching: .any).matching(identifier: "session.row.\($0)").firstMatch }
        for row in rows { XCTAssertTrue(row.waitForExistence(timeout: 3)) }
        for (first, second) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThan(first.frame.minY, second.frame.minY)
        }
        try saveSessionOrganizationEvidence(app, name: "sessions-pinned-active-newest-first")
        app.buttons["home.drawer.open"].tap()
        let drawerRows = ids.map { app.buttons["menu.chat.\($0)"] }
        for row in drawerRows { XCTAssertTrue(row.waitForExistence(timeout: 3)) }
        for (first, second) in zip(drawerRows, drawerRows.dropFirst()) {
            XCTAssertLessThan(first.frame.minY, second.frame.minY)
        }
        try saveSessionOrganizationEvidence(app, name: "sidebar-pinned-active-newest-first")
    }

    @MainActor
    func testSessionSectionControlsInPortraitAndLandscape() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-preview-ui-v3", "-loopdy.sessions.organizeByProjects", "YES"]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 5))
        app.buttons["tab.sessions"].tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let wide = orientation == .landscapeLeft
            let oriented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                wide ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [oriented], timeout: 4), .completed)
            let toggle = app.buttons["sessions.section-toggle.project:demo-loopdy"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3))
            for _ in 0..<6 where !toggle.isHittable { app.scrollViews["sessions.screen"].swipeUp() }
            XCTAssertTrue(toggle.isHittable)
            guard toggle.isHittable else { return }
            let before = toggle.value as? String
            toggle.tap()
            XCTAssertNotEqual(toggle.value as? String, before)
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, before)
            try saveSessionOrganizationEvidence(app, name: "sessions-layout-\(wide ? "landscape" : "portrait")-\(Int(app.frame.width))")
            app.buttons["home.drawer.open"].tap()
            let drawerToggle = app.buttons["quick-workspace.section-toggle.project:demo-loopdy"]
            XCTAssertTrue(drawerToggle.waitForExistence(timeout: 3))
            for _ in 0..<6 where !drawerToggle.isHittable { app.swipeUp() }
            XCTAssertTrue(drawerToggle.isHittable)
            guard drawerToggle.isHittable else { return }
            let drawerBefore = drawerToggle.value as? String
            drawerToggle.tap()
            XCTAssertNotEqual(drawerToggle.value as? String, drawerBefore)
            try saveSessionOrganizationEvidence(app, name: "sidebar-layout-\(wide ? "landscape" : "portrait")-\(Int(app.frame.width))")
            drawerToggle.tap()
            app.buttons["menu.done"].tap()
        }
    }

    @MainActor
    private func saveSessionOrganizationEvidence(_ app: XCUIApplication, name: String) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/loopdy-session-sections-proof", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = XCUIScreen.main.screenshot()
        let image = UIGraphicsImageRenderer(size: app.frame.size).image { _ in
            screenshot.image.draw(in: CGRect(origin: .zero, size: app.frame.size))
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLiveThinkingCardShowsNativeTextOutsideTheLiveToolFolder() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-live-reasoning-card", "-loopdy.demo.appearance", "light",
        ]
        app.launch()
        let thinking = app.buttons["chat.activity.thinking-ui:1:reasoning:0"]
        XCTAssertTrue(thinking.waitForExistence(timeout: 5))
        // "Thinking" while it runs; "Thought process" once a tool starts.
        XCTAssertTrue(thinking.label.contains("Thinking") || thinking.label.hasPrefix("Thought"), thinking.label)
        XCTAssertEqual(thinking.value as? String, "Expanded")
        let content = app.staticTexts["Visible reasoning token"]
        XCTAssertTrue(content.waitForExistence(timeout: 3), "Native reasoning text must be visible before the turn finishes.")
        // The running tool's folder lists its calls as they happen.
        let tools = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")).firstMatch
        XCTAssertTrue(tools.exists)
        XCTAssertEqual(tools.value as? String, "Expanded")
        XCTAssertFalse(tools.label.contains("Reasoning"))
        saveV2Evidence(app, name: "live-thinking-with-live-tools")
        thinking.tap()
        XCTAssertEqual(thinking.value as? String, "Collapsed")
        XCTAssertTrue(content.waitForNonExistence(timeout: 3))
        XCTAssertEqual(tools.value as? String, "Expanded", "Closing the thinking leaves the tool folder alone")
        thinking.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 3))
    }

    @MainActor
    func testExpandedComposerRemainsEditableDuringNativeThinking() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-live-reasoning-card", "-loopdy.demo.appearance", "light",
        ]
        app.launch()
        let input = messageComposer(in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Keep this unsent draft")
        let expand = app.buttons["chat.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let expanded = app.textViews["Expanded message"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 3))
        expanded.tap()
        expanded.typeText("\nSecond line")
        XCTAssertEqual(expanded.value as? String, "Keep this unsent draft\nSecond line")
        saveV2Evidence(app, name: "expanded-during-native-thinking")
        app.buttons["chat.composer.expanded.collapse"].tap()
        let compact = messageComposer(in: app)
        XCTAssertTrue(compact.waitForExistence(timeout: 3))
        XCTAssertEqual(compact.value as? String, "Keep this unsent draft\nSecond line")
        XCTAssertTrue(app.staticTexts["Visible reasoning token"].exists)
    }

    @MainActor
    func testLiquidGlassHeaderShowsCurrentShimmerPhraseAndClearsItWhenCompleted() throws {
        try verifyLiquidGlassHeaderActivity()
    }

    @MainActor
    func testLiquidGlassHeaderActivityRemainsReadableAtAccessibilityXXXL() throws {
        try verifyLiquidGlassHeaderActivity(accessibility: true)
    }

    @MainActor
    private func verifyLiquidGlassHeaderActivity(accessibility: Bool = false) throws {
        let app = makeApp()
        var common = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-reasoning-activity", "-test-reasoning-shimmer-header",
            "-loopdy.demo.appearance", "light",
        ]
        if accessibility {
            common += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = common
        app.launch()

        // iPhone chats lead with the big live avatar; the Dynamic Island (or
        // the line under the name) shows the work instead of this phrase.
        try XCTSkipIf(app.buttons["agent.hero.avatar"].waitForExistence(timeout: 5),
                      "The shimmer phrase header is the iPad and group chat header.")
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertEqual(identity.value as? String, "Burning the draft…")
        XCTAssertEqual(identity.label, "Chat with Avery Park")
        XCTAssertLessThanOrEqual(identity.frame.width, 240)
        if !accessibility {
            let firstFrame = identity.screenshot().pngRepresentation
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            XCTAssertNotEqual(
                identity.screenshot().pngRepresentation,
                firstFrame,
                "The active phrase must use the live Thinking Orbs text shimmer."
            )
        }
        let headerSurface = app.otherElements["chat.header-surface"]
        XCTAssertTrue(headerSurface.exists)
        XCTAssertLessThanOrEqual(
            identity.frame.maxY,
            headerSurface.frame.maxY + 1,
            "The activity phrase must remain inside the Liquid Glass header."
        )
        saveV2Evidence(app, name: UIDevice.current.userInterfaceIdiom == .pad
            ? "reasoning-shimmer-header-ipad\(accessibility ? "-accessibility-xxxl" : "")"
            : "reasoning-shimmer-header-iphone\(accessibility ? "-accessibility-xxxl" : "")")

        app.terminate()
        app.launchArguments = common + ["-test-reasoning-completed"]
        app.launch()
        XCTAssertTrue(identity.waitForExistence(timeout: 5))
        XCTAssertEqual(identity.value as? String, "")
    }

    @MainActor
    func testIPadReasoningChipReflectsRealActiveAndCompletedLifecycle() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad-only activity") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        let common = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-session-reasoning-high",
            "-loopdy.demo.appearance", "light",
        ]
        app.launchArguments = common + ["-test-reasoning-activity"]
        app.launch()

        let chip = app.buttons[
            "chat.activity.reasoning-fixture-event"
        ]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue(chip.label.contains("Thinking"))
        XCTAssertEqual(chip.value as? String, "Expanded")
        XCTAssertTrue(app.staticTexts["Using the current session context."].exists)
        saveV2Evidence(app, name: "restored-ipad-reasoning-active")
        chip.tap()
        XCTAssertEqual(chip.value as? String, "Collapsed")
        saveV2Evidence(app, name: "restored-ipad-reasoning-collapsed")
        chip.tap()
        XCTAssertEqual(chip.value as? String, "Expanded")

        app.terminate()
        app.launchArguments = common + ["-test-reasoning-activity", "-test-reasoning-completed"]
        app.launch()
        let completedTurn = app.buttons["chat.completed-turn:activity:reasoning-fixture-turn:reasoning-fixture-event"]
        XCTAssertTrue(completedTurn.waitForExistence(timeout: 5))
        XCTAssertEqual(completedTurn.value as? String, "Collapsed")
        completedTurn.tap()
        let completed = app.buttons[
            "chat.activity.reasoning-fixture-event"
        ]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertEqual(completed.label, "Thought process")
        XCTAssertEqual(completed.value as? String, "Collapsed")
        completed.tap()
        XCTAssertTrue(app.staticTexts["The reasoning phase finished."].waitForExistence(timeout: 3))
        saveV2Evidence(app, name: "restored-ipad-reasoning-completed")
    }

    @MainActor
    func testV3PhoneModelPopoverKeepsCompactWidth() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone-only layout") }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3"]
        app.launch()
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let panel = app.scrollViews["chat.session-controls.popover"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.width, 338, accuracy: 0.5)
        saveV2Evidence(app, name: "v3-phone-compact-picker")
    }

    @MainActor
    func testV3IPadWideModelPopoverAndCenteredChangesRail() throws {
        try verifyV3IPadPopoverAndRail()
    }

    @MainActor
    func testV3IPadWideModelPopoverAndCenteredChangesRailInLandscape() throws {
        try verifyV3IPadPopoverAndRail(landscape: true)
    }

    @MainActor
    func testV3IPadWideModelPopoverAtAccessibilityXXXL() throws {
        try verifyV3IPadPopoverAndRail(accessibility: true)
    }

    @MainActor
    private func verifyV3IPadPopoverAndRail(landscape: Bool = false, accessibility: Bool = false) throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad-only layout") }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-v3-header-context", "-loopdy.demo.appearance", "light"]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let options = app.buttons["chat.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = landscape ? .landscapeRight : .portrait
        expectation(for: NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        app.activate()
        // The context window lives in the ⋯ menu, not a rail above the message box.
        XCTAssertFalse(app.buttons["chat.session-context"].exists)
        XCTAssertTrue(openContextWindow(in: app).exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        let mode = landscape ? "landscape" : accessibility ? "accessibility" : "portrait"
        saveV2Evidence(app, name: "v3-ipad-centered-rail-\(mode)")
        options.tap()
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.quick-model."))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5))
        let panel = app.scrollViews["chat.session-controls.popover"]
        XCTAssertTrue(panel.exists)
        XCTAssertGreaterThanOrEqual(panel.frame.width, 560,
                                    "The iPad dropdown must use a wider tablet layout, not the 338pt phone column")
        XCTAssertLessThanOrEqual(panel.frame.width, 640)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(panel.frame.maxX, app.frame.maxX)
        saveV2Evidence(app, name: "v3-ipad-wide-picker-\(mode)")
        if !accessibility {
            let modelButtons = choices.allElementsBoundByIndex
            XCTAssertEqual(modelButtons.count, 3)
            if let first = modelButtons.first {
                for button in modelButtons {
                    XCTAssertEqual(button.frame.midY, first.frame.midY, accuracy: 0.5,
                                   "Use the available tablet width for one row of quick models")
                }
            }
            let alternative = try XCTUnwrap(modelButtons.first { !$0.isSelected })
            alternative.tap()
            let reasoning = app.descendants(matching: .any)["chat.reasoning-slider"].firstMatch
            XCTAssertTrue(reasoning.exists)
            for _ in 0..<3 where !panel.frame.insetBy(dx: 0, dy: 12).contains(reasoning.frame) { panel.swipeUp() }
            XCTAssertTrue(panel.frame.insetBy(dx: 0, dy: 12).contains(reasoning.frame),
                          "The whole reasoning control must be visible before dragging it")
            XCTAssertTrue(reasoning.isHittable)
            reasoning.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: reasoning.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65)))
            let apply = app.buttons["chat.session-controls.apply"]
            for _ in 0..<3 where !apply.isHittable { panel.swipeUp() }
            XCTAssertTrue(apply.isEnabled)
            XCTAssertTrue(apply.isHittable)
            apply.tap()
            XCTAssertTrue(app.buttons["chat.models.see-all"].waitForNonExistence(timeout: 5))
            XCTAssertTrue(options.isHittable)
        }
    }

    @MainActor
    func testV3ModelPickerOccupiesHeaderCenter() throws {
        try verifyV3HeaderCenter()
    }

    @MainActor
    func testV3ModelPickerOccupiesHeaderCenterAtAccessibilityXXXL() throws {
        try verifyV3HeaderCenter(accessibility: true)
    }

    @MainActor
    func testV3ContextRingAboveComposerActionInLandscape() throws {
        try verifyV3HeaderCenter(landscape: true)
    }

    @MainActor
    private func verifyV3HeaderCenter(accessibility: Bool = false, landscape: Bool = false) throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-v3-header-context", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists, "The context window lives in the ⋯ menu")
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let orientationMatches = NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }
        expectation(for: orientationMatches, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let canvas = app.descendants(matching: .any)["chat.canvas"].firstMatch
        for hasContext in [true, false] {
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            let title = app.staticTexts["chat.session-title"]
            XCTAssertFalse(title.exists)
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertLessThan(picker.frame.midX, canvas.frame.midX)
                XCTAssertGreaterThanOrEqual(picker.frame.minX, canvas.frame.minX + 16)
            } else {
                XCTAssertEqual(picker.frame.midX, app.frame.midX, accuracy: 0.5)
            }
            XCTAssertEqual(picker.frame.midY, chatNewChatButton(in: app).frame.midY, accuracy: 0.5)
            XCTAssertTrue(picker.wait(for: \.isHittable, toEqual: true, timeout: 3))
            for label in picker.staticTexts.allElementsBoundByIndex {
                XCTAssertGreaterThanOrEqual(label.frame.minY, picker.frame.minY - 0.5)
                XCTAssertLessThanOrEqual(label.frame.maxY, picker.frame.maxY + 0.5)
            }
            XCTAssertFalse(app.buttons["chat.people"].exists)
            if hasContext {
                XCTAssertGreaterThanOrEqual(picker.frame.minX, app.frame.minX + 16)
            }
            saveV2Evidence(app, name: "v3-header-center-\(hasContext ? "context" : "new-chat")-\(accessibility ? "accessibility" : "normal")-\(landscape ? "landscape" : "portrait")")
            if hasContext {
                if !landscape {
                    XCTAssertTrue(openContextWindow(in: app).exists)
                    XCTAssertTrue(app.staticTexts["Context window"].waitForExistence(timeout: 3))
                    // Isolate each popover so dismissal does not select a model row.
                    app.terminate()
                    app.launch()
                    picker.tap()
                    XCTAssertTrue(app.buttons["chat.models.see-all"].waitForExistence(timeout: 3))
                    app.terminate()
                    app.launch()
                }
                chatNewChatButton(in: app).tap(); confirmNewChatPicker(in: app)
            }
        }
    }

    @MainActor
    func testV3UsesCompactModelPickerAndFooterNewChat() throws {
        try verifyV3PreferredControls()
    }

    @MainActor
    func testV3PreferredControlsAtAccessibilityXXXL() throws {
        try verifyV3PreferredControls(accessibility: true)
    }

    @MainActor
    func testV3MonochromeNewChatControlsInDarkMode() throws {
        try verifyV3PreferredControls(dark: true)
    }

    @MainActor
    private func verifyV3PreferredControls(accessibility: Bool = false, dark: Bool = false) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", dark ? "dark" : "light", "-loopdy.appearance.theme", "loopdy"]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let model = app.buttons["chat.session-controls"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(model.frame.width, 240.5)
        XCTAssertTrue(model.isHittable)
        let headerCreate = chatNewChatButton(in: app)
        XCTAssertTrue(headerCreate.isHittable)
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(headerCreate.frame.width, isPad ? 80 : 64, accuracy: 0.5)
        XCTAssertEqual(headerCreate.frame.height, isPad ? 80 : 64, accuracy: 0.5)
        let headerScreenshot = app.screenshot().image
        let headerMark = try headerGlyphBounds(in: headerCreate.frame, screenshot: headerScreenshot,
                                               appFrame: app.frame, bright: dark)
        XCTAssertEqual(headerMark.width / headerMark.height, 256.0 / 176.0, accuracy: 0.12)
        XCTAssertEqual(headerMark.midX, headerCreate.frame.midX, accuracy: 0.75)
        // Quick Workspace moved into the ⋯ menu; the options control is the other header glyph.
        let menu = app.buttons["chat.options"]
        XCTAssertEqual(menu.frame.width, 64, accuracy: 0.5)
        XCTAssertEqual(menu.frame.height, 64, accuracy: 0.5)
        XCTAssertEqual(headerCreate.frame.midY, menu.frame.midY, accuracy: 0.5,
                       "Only the infinity glyph moves; the control frames remain centered")
        let menuMark = try headerGlyphBounds(in: menu.frame,
                                             screenshot: headerScreenshot, appFrame: app.frame, bright: dark)
        XCTAssertEqual(headerMark.midY, headerCreate.frame.midY, accuracy: 0.75,
                       "Center infinity ink within its circle, matching the side-menu action")
        XCTAssertGreaterThanOrEqual(menuMark.width, 24)
        let appearance = dark ? "dark" : (accessibility ? "accessibility" : "light")
        saveV2Evidence(app, name: "v3-monochrome-header-\(appearance)")
        openChatWorkspaceMenu(in: app)
        let create = app.buttons["menu.new-chat"]
        let workspace = app.buttons["menu.folder"]
        XCTAssertTrue(create.waitForExistence(timeout: 4))
        XCTAssertEqual(app.buttons.matching(identifier: "menu.new-chat").count, 1)
        XCTAssertEqual(create.frame.width, 64, accuracy: 0.5)
        XCTAssertEqual(create.frame.height, 64, accuracy: 0.5)
        XCTAssertLessThanOrEqual(workspace.frame.width, 200.5)
        XCTAssertGreaterThanOrEqual(create.frame.minX, workspace.frame.maxX + 8)
        XCTAssertEqual(create.frame.midY, workspace.frame.midY, accuracy: 0.5)
        XCTAssertGreaterThan(create.frame.midY, app.frame.height * 0.7)
        XCTAssertTrue(create.isHittable)
        XCTAssertTrue(workspace.isHittable)
        let footerMark = try headerGlyphBounds(in: create.frame, screenshot: app.screenshot().image,
                                               appFrame: app.frame, bright: dark)
        XCTAssertEqual(footerMark.width / footerMark.height, 256.0 / 176.0, accuracy: 0.12)
        XCTAssertEqual(footerMark.midX, create.frame.midX, accuracy: 0.75)
        XCTAssertEqual(footerMark.midY, create.frame.midY, accuracy: 0.75)
        XCTAssertEqual(footerMark.width, headerMark.width * (isPad ? 36.0 / 46.0 : 1), accuracy: 1)
        saveV2Evidence(app, name: "v3-monochrome-footer-\(appearance)")
    }

    @MainActor
    func testV3GlassAnchorRoutesEveryTab() throws {
        try verifyV3GlassAnchor()
    }

    @MainActor
    func testV3GlassAnchorInDarkMode() throws {
        try verifyV3GlassAnchor(dark: true)
    }

    @MainActor
    func testV3GlassAnchorKeepsNewChatAvailableAtAccessibilityXXXL() throws {
        try verifyV3GlassAnchor(accessibility: true)
    }

    @MainActor
    private func verifyV3GlassAnchor(dark: Bool = false, accessibility: Bool = false) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", dark ? "dark" : "light",
            "-loopdy.appearance.theme", "loopdy"]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let create = app.buttons["root.new-chat"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertEqual(create.frame.width, 64, accuracy: 0.5)
        XCTAssertEqual(create.frame.height, 64, accuracy: 0.5)
        let ink = try headerGlyphBounds(in: create.frame, screenshot: app.screenshot().image,
                                        appFrame: app.frame, bright: dark)
        XCTAssertEqual(ink.width / ink.height, 256.0 / 176.0, accuracy: 0.12)
        for tab in ["home", "agents", "sessions", "profile"] {
            let control = app.buttons["tab.\(tab)"]
            XCTAssertTrue(control.isHittable)
            if accessibility {
                XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
                XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
                XCTAssertFalse(control.frame.intersects(create.frame), "Navigation destinations must never pass behind New Chat")
            }
            control.tap()
            XCTAssertTrue(control.isSelected)
            XCTAssertTrue(create.isHittable)
            XCTAssertEqual(app.otherElements.matching(identifier: "primary-navigation").count, 1)
            saveV2Evidence(app, name: "v3-anchor-\(tab)-\(accessibility ? "accessibility" : dark ? "dark" : "light")")
        }
        create.tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["root.new-chat"].exists)
    }

    @MainActor
    func testV3TaskAndGoalSheetsUseCurrentSessionState() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-test-v3-session-status", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        app.launch()
        let tasks = app.buttons["chat.session-status.tasks"]
        XCTAssertTrue(tasks.waitForExistence(timeout: 5))
        tasks.tap()
        XCTAssertTrue(app.staticTexts["Review the current plan"].waitForExistence(timeout: 4))
        for text in ["Completed", "In progress", "Pending", "Cancelled"] {
            XCTAssertTrue(app.staticTexts[text].exists)
        }
        saveV2Evidence(app, name: "v3-session-tasks")
        app.buttons["Done"].tap()
        app.buttons["chat.session-status.goal"].tap()
        let editor = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Goal text")).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        XCTAssertEqual(editor.value as? String, "Finish the current plan")
        XCTAssertFalse(app.buttons["Save goal"].isEnabled)
        XCTAssertTrue(app.buttons["Pause goal"].isHittable)
        saveV2Evidence(app, name: "v3-goal")
        app.buttons["Pause goal"].tap()
        XCTAssertTrue(app.buttons["chat.session-status.goal"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testV3ChatHasNoBotModeButton() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
            app.launch()
            let model = app.buttons["chat.session-controls"]
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["chat.people"].exists,
                           "Bot-to-bot conversation cards must not introduce a Bot Mode entry button")
            XCTAssertFalse(app.buttons["Add agents"].exists)
            XCTAssertFalse(app.buttons["People & Chat"].exists)
            XCTAssertTrue(model.isHittable)
            XCTAssertTrue(app.buttons["chat.options"].isHittable)
            XCTAssertTrue(chatNewChatButton(in: app).isHittable)
            XCTAssertTrue(messageComposer(in: app).exists)
            saveV2Evidence(app, name: "v3-no-bot-mode-button-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testV3LandscapeAttachmentAndVoiceControls() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(for: NSPredicate { _, _ in app.frame.width > app.frame.height }, evaluatedWith: app)
        wait(for: [landscape], timeout: 5)
        XCTAssertTrue(messageComposer(in: app).isHittable)
        saveV2Evidence(app, name: "v3-chat-landscape")
        app.buttons["chat.attachment"].tap()
        let voice = app.buttons["chat.action.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 4))
        XCTAssertTrue(voice.isHittable)
        saveV2Evidence(app, name: "v3-attachment-drawer")
        voice.tap()
        let end = app.buttons["End voice chat"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(end.isHittable)
        saveV2Evidence(app, name: "v3-voice")
        end.tap()
    }

    @MainActor
    func testV3AccessibilityHeaderAndComposerRemainUsable() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(messageComposer(in: app).isHittable)
        XCTAssertTrue(app.buttons["chat.options"].isHittable)
        XCTAssertTrue(chatNewChatButton(in: app).isHittable)
        XCTAssertTrue(app.buttons["chat.session-controls"].isHittable)
        saveV2Evidence(app, name: "v3-accessibility")
    }

    @MainActor
    func testV3ChatOpensWithCurrentModelAndWorkingComposer() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-session-model", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        app.launch()
        let header = app.descendants(matching: .any)["chat.header-surface"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.value as? String, "UI V3")
        XCTAssertTrue(app.buttons["chat.options"].isHittable)
        XCTAssertTrue(chatNewChatButton(in: app).isHittable)
        let headerImage = app.screenshot().image
        // V3 centers the infinity mark and menu strokes in their own controls;
        // their different ink heights do not share a lower edge.
        for identifier in ["chat.new-chat", "chat.options"] {
            let control = app.buttons[identifier]
            let glyph = try headerGlyphBounds(in: control.frame, screenshot: headerImage, appFrame: app.frame)
            XCTAssertEqual(glyph.midY, control.frame.midY, accuracy: 0.75)
        }
        let model = app.buttons["chat.session-controls"]
        XCTAssertTrue(model.exists)
        XCTAssertTrue((model.value as? String)?.contains("session-chosen-model") == true)
        saveV2Evidence(app, name: "v3-chat-light")
        let input = messageComposer(in: app)
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("A native V3 draft")
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
        app.buttons["chat.composer.expand"].tap()
        XCTAssertTrue(app.textViews["Expanded message"].waitForExistence(timeout: 4))
        saveV2Evidence(app, name: "v3-expanded-draft")
        app.buttons["chat.composer.expanded.collapse"].tap()
        XCTAssertTrue((messageComposer(in: app).value as? String ?? "").contains("A native V3 draft"))
        let compactInput = messageComposer(in: app)
        clearComposer(compactInput)
        compactInput.typeText("/")
        let help = app.buttons["reference-hub.command.help"]
        XCTAssertTrue(help.waitForExistence(timeout: 4))
        help.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.otherElements["reference-hub.drawer"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(messageComposer(in: app).value as? String, "/help ")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        messageComposer(in: app).typeText("details")
        XCTAssertTrue(app.buttons["Send message"].isEnabled)
    }

    @MainActor
    func testExistingSessionModelIsVisibleBeforePickerInteraction() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-test-session-model", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        let chip = app.buttons["chat.session-controls"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertTrue((chip.value as? String)?.contains("session-chosen-model") == true, String(describing: chip.value))
        XCTAssertFalse(app.buttons["chat.models.see-all"].exists)
        saveV2Evidence(app, name: "session-model-before-picker")
    }

    @MainActor
    func testV2CapabilitySheetHasStableWidthWhileHostSettingsLoad() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-delayed-capability-control", "-loopdy.appearance.ui-v2-enabled", "YES", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openSkillsAndTools(in: app)
        let skill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Weather, Skills,")).firstMatch
        XCTAssertTrue(skill.waitForExistence(timeout: 5))
        skill.tap()
        let loading = app.staticTexts["Reading host settings…"]
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let identifier = app.staticTexts["weather"]
        let initialLeft = identifier.frame.minX
        XCTAssertEqual(initialLeft, app.frame.minX + 20, accuracy: 1)
        saveV2Evidence(app, name: "capability-loading")
        XCTAssertTrue(app.buttons["skills-tools.control.toggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(identifier.frame.minX, initialLeft, accuracy: 1)
        XCTAssertGreaterThanOrEqual(app.buttons["Done"].frame.maxX, app.frame.maxX - 32)
        XCTAssertTrue(app.buttons["Done"].isHittable)
        saveV2Evidence(app, name: "capability-loaded")
    }

    @MainActor
    func testV2NativeRichFormattingExportsMarkdown() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Hello ")
        app.buttons["chat.composer.expand"].tap()
        app.buttons["reference-hub.editor-mode"].tap()
        let bold = app.buttons["chat.composer.expanded.bold"]
        XCTAssertTrue(bold.waitForExistence(timeout: 5))
        bold.tap()
        XCTAssertTrue(bold.isSelected, "Active typing format must be visible and accessible")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.textViews["Expanded message"].typeText("bold words")
        XCTAssertTrue(bold.isSelected)
        bold.tap()
        XCTAssertFalse(bold.isSelected)
        let richShot = XCTAttachment(screenshot: app.screenshot())
        richShot.name = "v2-native-rich-draft"
        richShot.lifetime = .keepAlways
        add(richShot)
        app.buttons["chat.composer.expanded.mode"].tap()
        let source = app.textViews["Expanded message"].value as? String ?? ""
        XCTAssertTrue(source.contains("**") || source.contains("__"), "Native font formatting must have Markdown output")
        XCTAssertTrue(source.contains("bold"))
        XCTAssertTrue(source.contains("words"))
    }

    @MainActor
    func testV2LongExpandedDraftAllowsFlingAwayFromCaret() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let draft = (1...40).map { "Line \($0) long prompt for scroll verification." }.joined(separator: "\n")
        composer.tap()
        composer.typeText(draft)
        let expand = app.buttons["chat.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        let editor = app.textViews["Expanded message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.swipeUp(velocity: .fast)
        editor.swipeUp(velocity: .fast)
        saveV2Evidence(app, name: "expanded-before-fling")
        editor.swipeDown(velocity: .fast)
        saveV2Evidence(app, name: "expanded-after-fling")
        let stableKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [stableKeyboard], timeout: 2), .completed)
        saveV2Evidence(app, name: "expanded-settled")
        XCTAssertEqual(editor.value as? String, draft)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    private func saveV2Evidence(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let size = app.frame.size
            let png = UIGraphicsImageRenderer(size: size).pngData { _ in
                screenshot.image.draw(in: CGRect(origin: .zero, size: size))
            }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    func testV2ExpandedSlashSelectionKeepsKeyboardAndContinuedTyping() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("/he")
        // Establish the compact query before transferring its live editor.
        XCTAssertTrue(app.buttons["reference-hub.command.help"].waitForExistence(timeout: 5))
        app.buttons["chat.composer.expand"].tap()
        let panel = app.descendants(matching: .any)["chat.composer.expanded"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "expanded-slash-transfer-hierarchy"
        hierarchy.lifetime = .deleteOnSuccess
        add(hierarchy)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews["Expanded message"].value as? String, "/he")
        let suggestion = panel.buttons["reference-hub.command.help"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        guard suggestion.exists else { return }
        XCTAssertTrue(suggestion.isHittable)
        suggestion.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(panel.otherElements["reference-hub.drawer"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let editor = app.textViews["Expanded message"]
        editor.typeText("details")
        XCTAssertTrue((editor.value as? String ?? "").contains("/help details"))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testV2NewChatButtonAlignsWithHeaderControls() throws {
        try verifyV2HeaderControlAlignment()
    }

    @MainActor
    func testV2SidePanelNewChatSymbolIsCentered() throws {
        try verifyV2SidePanelSymbolCenter()
    }

    @MainActor
    func testV2SidePanelNewChatSymbolIsCenteredAtAccessibilityXXXL() throws {
        try verifyV2SidePanelSymbolCenter(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    @MainActor
    private func verifyV2SidePanelSymbolCenter(contentSize: String? = nil) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES", "-loopdy.demo.appearance", "light"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 5))
        openChatWorkspaceMenu(in: app)
        let create = app.buttons["menu.new-chat"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable)
        // Legacy preferences now display V3's black infinity mark in light mode.
        let glyph = try headerGlyphBounds(in: create.frame, screenshot: app.screenshot().image,
                                          appFrame: app.frame)
        XCTAssertEqual(glyph.midX, create.frame.midX, accuracy: 0.75)
        XCTAssertEqual(glyph.midY, create.frame.midY, accuracy: 0.75)
        XCTAssertEqual(glyph.width / glyph.height, 256.0 / 176.0, accuracy: 0.12)
        XCTAssertEqual(create.frame.width, 64, accuracy: 0.5)
        XCTAssertEqual(create.frame.height, 64, accuracy: 0.5)
        saveV2Evidence(app, name: contentSize == nil ? "side-panel-symbol-centered" : "side-panel-symbol-centered-accessibility")
    }

    @MainActor
    func testV2NewChatButtonAlignsWithHeaderControlsAtAccessibilityXXXL() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES", "-loopdy.demo.appearance", "light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let create = chatNewChatButton(in: app)
        let options = app.buttons["chat.options"]
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(options.exists)
        XCTAssertTrue(picker.exists)
        // Legacy preferences migrate to the shipping V3 interface.
        XCTAssertEqual(app.descendants(matching: .any)["chat.header-surface"].firstMatch.value as? String, "UI V3")
        XCTAssertEqual(create.frame.midY, options.frame.midY, accuracy: 1)
        XCTAssertEqual(create.frame.midY, picker.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        XCTAssertTrue(create.isHittable)
        let screenshot = app.screenshot().image
        for control in [create, options] {
            let glyph = try headerGlyphBounds(in: control.frame, screenshot: screenshot, appFrame: app.frame)
            XCTAssertEqual(glyph.midY, control.frame.midY, accuracy: 0.75,
                           "V3 centers each visible symbol within its control, including at accessibility sizes")
        }
        saveV2Evidence(app, name: "header-aligned-accessibility")
    }

    @MainActor
    private func verifyV2HeaderControlAlignment(contentSize: String? = nil) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-loopdy.appearance.ui-v2-enabled", "YES", "-loopdy.demo.appearance", "light"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        let create = chatNewChatButton(in: app)
        let options = app.buttons["chat.options"]
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(options.exists)
        XCTAssertTrue(picker.exists)
        XCTAssertEqual(create.frame.midY, options.frame.midY, accuracy: 1)
        XCTAssertEqual(create.frame.midY, picker.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        XCTAssertTrue(create.isHittable)
        let screenshot = app.screenshot().image
        for control in [create, options] {
            let glyph = try headerGlyphBounds(in: control.frame, screenshot: screenshot, appFrame: app.frame)
            XCTAssertEqual(glyph.midY, control.frame.midY, accuracy: 0.75,
                           "V3 centers each visible symbol within its control")
        }
        saveV2Evidence(app, name: contentSize == nil ? "header-aligned" : "header-aligned-accessibility")
    }

    private func headerGlyphBottom(in frame: CGRect, screenshot: UIImage, appFrame: CGRect) throws -> CGFloat {
        try headerGlyphBounds(in: frame, screenshot: screenshot, appFrame: appFrame).maxY
    }

    private func headerGlyphBounds(in frame: CGRect, screenshot: UIImage, appFrame: CGRect, bright: Bool = false) throws -> CGRect {
        let image = try XCTUnwrap(screenshot.cgImage)
        let scale = CGFloat(image.width) / appFrame.width
        let inner = frame.insetBy(dx: bright ? 8 : 4, dy: bright ? 8 : 4)
        let cropRect = CGRect(x: (inner.minX - appFrame.minX) * scale,
                              y: (inner.minY - appFrame.minY) * scale,
                              width: inner.width * scale, height: inner.height * scale).integral
        let crop = try XCTUnwrap(image.cropping(to: cropRect))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let bounds = try pixels.withUnsafeMutableBytes { storage -> CGRect in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: crop.width,
                height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            var minX = crop.width, minY = crop.height, maxX = -1, maxY = -1
            for y in 0..<crop.height {
                for x in 0..<crop.width {
                    let index = (y * crop.width + x) * 4
                    let isInk = bright
                        ? storage[index] > 220 && storage[index + 1] > 220 && storage[index + 2] > 220
                        : storage[index] < 80 && storage[index + 1] < 80 && storage[index + 2] < 80
                    if isInk && storage[index + 3] > 200 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            guard maxX >= minX, maxY >= minY else {
                return try XCTUnwrap(nil as CGRect?, "No symbol pixels in the light-mode fixture")
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return CGRect(x: (cropRect.minX + bounds.minX) / scale,
                      y: (cropRect.minY + bounds.minY) / scale,
                      width: bounds.width / scale, height: bounds.height / scale)
    }

    @MainActor
    func testV2SignedOutModesFitPortraitAndLandscape() throws {
        let app = makeApp()
        app.launchArguments = ["-force-signed-out-onboarding", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let gate = app.descendants(matching: .any).matching(identifier: "link.account.v2-gate").firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 6))
        let signup = app.buttons["link.account.mode.sign-up"]
        XCTAssertTrue(signup.isHittable)
        let signinShot = XCTAttachment(screenshot: app.screenshot())
        signinShot.name = "v2-sign-in-\(Int(app.frame.width))"
        signinShot.lifetime = .keepAlways
        add(signinShot)
        signup.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(gate.waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["link.account.mode.sign-in"].isHittable)
        let signupShot = XCTAttachment(screenshot: app.screenshot())
        signupShot.name = "v2-sign-up-landscape-\(Int(app.frame.width))"
        signupShot.lifetime = .keepAlways
        add(signupShot)
    }

    @MainActor
    func testAppearanceKeepsThemesWithoutLegacyInterfaceSelection() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.appearance.interface-version", "v1"]
        app.launch()
        openSettings(in: app)
        let appearance = settingsRow("settings.menu.appearance", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 4))
        appearance.tap()
        XCTAssertTrue(app.buttons["settings.themes"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.segmentedControls["settings.interface-version"].exists)
        XCTAssertFalse(app.buttons["V1"].exists)
        XCTAssertFalse(app.buttons["V2"].exists)
        saveV2Evidence(app, name: "v3-only-appearance")
    }
    /// The production composer is a UIKit-backed text view on iOS 17 so it
    /// preserves Apple's native selection menu. XCTest classifies that control
    /// as a text view on some runtimes and as a text field on others. Keep the
    /// UI contract (labelled Message input) stable across both classifications.
    @MainActor
    private func messageComposer(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["Message"]
        return textField.exists ? textField : app.textViews["Message"]
    }

    @MainActor
    private func clearComposer(_ composer: XCUIElement) {
        guard let value = composer.value as? String, value != "Message", !value.isEmpty else {
            return
        }
        composer.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
    }

    @MainActor
    func testSubagentDetailStreamsAndReconcilesCanonicalActivityWithoutReopening() throws {
        try verifySubagentStream()
    }

    @MainActor
    func testV3SubagentDetailStreamsAndReconcilesCanonicalActivity() throws {
        try verifySubagentStream(v3: true)
    }

    @MainActor
    private func verifySubagentStream(v3: Bool = false) throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-start-chat",
            "-test-subagent-stream-fixture",
        ]
        if v3 {
            app.launchArguments += ["-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "dark"]
        }
        app.launch()

        let rail = app.buttons["chat.session-status.subagents"]
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Ready"),
            object: rail
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 5),
            .completed,
            "The fixture must expose the parent route only after the exact child record, initial activity, and displayed roster agree."
        )

        app.buttons["chat.session-status.subagents"].tap()
        let child = app.buttons["subagent.roster.fixture-child-session"]
        XCTAssertTrue(child.waitForExistence(timeout: 3))
        if v3 { saveV2Evidence(app, name: "v3-subagents-roster") }
        child.tap()

        let detail = app.scrollViews["subagent.detail.fixture-child-session"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.staticTexts["subagent.detail.status.fixture-child-session"].label,
            "Active subagent"
        )
        XCTAssertFalse(app.descendants(matching: .any)["subagent.detail.persistence-placeholder"].exists)

        let workTrail = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")
        ).firstMatch
        XCTAssertTrue(workTrail.waitForExistence(timeout: 3))
        workTrail.tap()
        XCTAssertTrue(app.buttons["chat.activity.fixture-initial-live"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
            ).count,
            1
        )

        if v3 { saveV2Evidence(app, name: "v3-subagent-live-detail") }
        let emitSecond = app.buttons["fixture.subagent-stream.emit-second"]
        XCTAssertTrue(emitSecond.waitForExistence(timeout: 3))
        emitSecond.tap()
        XCTAssertTrue(
            app.buttons["chat.activity.fixture-second-live"].waitForExistence(timeout: 3),
            "The second event must update the already-open detail route."
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
            ).count,
            2
        )

        let emitTerminal = app.buttons["fixture.subagent-stream.emit-terminal"]
        XCTAssertTrue(emitTerminal.waitForExistence(timeout: 3))
        emitTerminal.tap()

        let failedStatus = app.staticTexts["subagent.detail.status.fixture-child-session"]
        let terminalState = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Failed child session"),
            object: failedStatus
        )
        XCTAssertEqual(XCTWaiter.wait(for: [terminalState], timeout: 3), .completed)
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "chat.activity.fixture-canonical-terminal")
            ).count,
            1,
            "Canonical catch-up must leave exactly one projected semantic tool entry."
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "chat.activity.fixture-second-live")
            ).count,
            0,
            "Canonical catch-up must replace, not duplicate, the live semantic entry."
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
            ).count,
            2,
            "The initial tool and reconciled canonical tool must remain the only projected activity rows."
        )
        XCTAssertTrue(app.buttons["chat.activity.fixture-canonical-terminal"].label.contains("Failed"))
        XCTAssertTrue(detail.exists, "The child detail must remain open through live and terminal updates.")
        if v3 { saveV2Evidence(app, name: "v3-subagent-terminal-detail") }
    }

    @MainActor
    func testAgentCollaborationCardExpandsItsAttributedTranscript() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat", "-demo-collaboration"]
        app.launch()

        let card = app.descendants(matching: .any)["chat.collaboration.demo-agent-collaboration"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertEqual(card.value as? String, "Collapsed")
        card.tap()

        let transcript = app.descendants(matching: .any)[
            "chat.collaboration.demo-agent-collaboration.transcript"
        ]
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Please review the launch plan and flag any travel risks."].exists)
    }

    @MainActor
    func testSignedOutOnboardingBlocksTheWorkspaceUntilAccountSetup() throws {
        let app = makeApp()
        app.launchArguments = ["-force-signed-out-onboarding"]
        app.launch()

        XCTAssertTrue(app.scrollViews["link.account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["link.account.sign-in"].exists)
        XCTAssertTrue(app.buttons["link.account.create"].exists)
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
        XCTAssertFalse(app.buttons["root.new-chat"].exists)
    }

    @MainActor
    func testShellUsesOnlyTheCustomPrimaryNavigationBar() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.tabBars.count,
            0,
            "The native TabView bar must remain hidden when bighelp's custom floating bar is visible."
        )
        XCTAssertEqual(
            app.otherElements.matching(identifier: "primary-navigation").count,
            1,
            "The workspace root must expose exactly one attached primary navigation bar."
        )
        XCTAssertFalse(app.buttons["tab.inbox"].exists)
    }

    @MainActor
    func testPrimaryNavigationHasFourEqualDestinationsAndSeparateComposeAction() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let navigation = app.otherElements["primary-navigation"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 3))

        let identifiers = [
            "tab.agents",
            "tab.sessions",
            "tab.scheduled-tasks",
            "tab.workspace",
            "root.new-chat",
        ]
        let controls = identifiers.map { app.buttons[$0] }
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 3), "Missing primary navigation control: \(control)")
        }

        XCTAssertEqual(
            navigation.buttons.count,
            5,
            "Primary navigation must expose exactly five controls."
        )

        let destinations = Array(controls.prefix(4))
        for (left, right) in zip(destinations, destinations.dropFirst()) {
            XCTAssertEqual(right.frame.minX, left.frame.maxX, accuracy: 1)
        }
        for control in destinations {
            XCTAssertEqual(control.frame.width, destinations[0].frame.width, accuracy: 1)
            XCTAssertEqual(control.frame.height, destinations[0].frame.height, accuracy: 1)
            XCTAssertEqual(control.frame.midY, destinations[0].frame.midY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        let compose = controls[4]
        XCTAssertGreaterThan(compose.frame.minX, destinations[3].frame.maxX)
        XCTAssertGreaterThanOrEqual(compose.frame.width, 44)
        XCTAssertGreaterThanOrEqual(compose.frame.height, 44)
        XCTAssertEqual(compose.frame.midY, destinations[0].frame.midY, accuracy: 1)

        let navigationFrame = navigation.frame
        controls[1].tap()
        XCTAssertTrue(
            app.scrollViews["sessions.screen"].waitForExistence(timeout: 3),
            "The Sessions control must open the existing Sessions screen."
        )
        XCTAssertEqual(
            app.otherElements.matching(identifier: "primary-navigation").count,
            1,
            "Sessions must retain the one root-owned navigation bar."
        )
        XCTAssertEqual(navigation.frame, navigationFrame)
        XCTAssertTrue(controls[1].isSelected)
        XCTAssertFalse(app.buttons["Back"].exists)
    }

    @MainActor
    func testPrimaryNavigationGlassCapturesLightAndDarkReviewEvidence() throws {
        let proofDirectory = URL(
            fileURLWithPath: "/private/tmp/loopdy-session-project-organization-proof",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: proofDirectory,
            withIntermediateDirectories: true
        )
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-loopdy.demo.appearance",
            "light",
        ]
        app.launch()

        let controls = ["tab.agents", "tab.sessions", "tab.scheduled-tasks", "tab.workspace", "root.new-chat"]
            .map { app.buttons[$0] }
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            XCTAssertTrue(control.isHittable)
        }
        let lightScreenshot = app.screenshot()
        try lightScreenshot.pngRepresentation.write(
            to: proofDirectory.appendingPathComponent("bottom-anchor-glass-light.png"),
            options: .atomic
        )
        let lightEvidence = XCTAttachment(screenshot: lightScreenshot)
        lightEvidence.name = "Primary navigation glass, light appearance"
        lightEvidence.lifetime = .keepAlways
        add(lightEvidence)

        app.terminate()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-loopdy.demo.appearance",
            "dark",
        ]
        app.launch()
        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
            XCTAssertTrue(control.isHittable)
        }
        let darkScreenshot = app.screenshot()
        try darkScreenshot.pngRepresentation.write(
            to: proofDirectory.appendingPathComponent("bottom-anchor-glass-dark.png"),
            options: .atomic
        )
        let darkEvidence = XCTAttachment(screenshot: darkScreenshot)
        darkEvidence.name = "Primary navigation glass, dark appearance"
        darkEvidence.lifetime = .keepAlways
        add(darkEvidence)
    }

    @MainActor
    func testSessionLongPressActionsAndChatTitleRenamePresentation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        XCTAssertTrue(app.buttons["tab.sessions"].waitForExistence(timeout: 3))
        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))

        let sessionRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session.row.'")
        )
        let row = sessionRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.press(forDuration: 0.8)

        for action in ["Rename", "Pin", "Archive", "Delete"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 2), "Missing \(action) session action")
        }
        let actionsScreenshot = XCTAttachment(screenshot: app.screenshot())
        actionsScreenshot.name = "Session long-press actions"
        actionsScreenshot.lifetime = .keepAlways
        add(actionsScreenshot)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.alerts["Rename chat"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        app.buttons["Cancel"].tap()

        let deleteRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session.row.'")
        ).firstMatch
        XCTAssertTrue(deleteRow.waitForExistence(timeout: 2))
        deleteRow.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 2))
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.alerts["Delete Session?"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Cancel"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Cancel"].tap()

        let reopenedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'session.row.'")
        ).firstMatch
        XCTAssertTrue(reopenedRow.waitForExistence(timeout: 2))
        reopenedRow.tap()

        let sessionTitle = app.descendants(matching: .any)["chat.session-title"]
        XCTAssertTrue(sessionTitle.waitForExistence(timeout: 3))
        sessionTitle.press(forDuration: 0.8)
        XCTAssertTrue(app.alerts["Rename chat"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields.firstMatch.exists)
        let titleScreenshot = XCTAttachment(screenshot: app.screenshot())
        titleScreenshot.name = "Chat title long-press rename"
        titleScreenshot.lifetime = .keepAlways
        add(titleScreenshot)
    }

    @MainActor
    func testSessionProjectFilterIsReachableAndFiltersFixtureSessions() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let sessionsTab = app.buttons["tab.sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 3))
        sessionsTab.tap()
        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))

        let projectFilter = app.buttons["sessions.filter.project"]
        XCTAssertTrue(projectFilter.waitForExistence(timeout: 3))
        XCTAssertTrue(projectFilter.isHittable)
        XCTAssertEqual(projectFilter.value as? String, "All projects")

        projectFilter.tap()
        XCTAssertTrue(app.buttons["bighelp"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Travel Planning"].exists)
        XCTAssertTrue(app.buttons["Unassigned"].exists)
        app.buttons["bighelp"].tap()

        XCTAssertEqual(projectFilter.value as? String, "bighelp")
        XCTAssertTrue(app.staticTexts["Finance"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Travel"].exists)
    }

    @MainActor
    func testOrganizeChatsByProjectsSettingGroupsSessionsAndQuickWorkspace() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        openSettings(in: app)
        let workspaceSettings = settingsRow("settings.menu.workspace", in: app)
        XCTAssertTrue(workspaceSettings.waitForExistence(timeout: 3))
        workspaceSettings.tap()

        let organize = app.switches["settings.organize-chats-by-projects"]
        XCTAssertTrue(organize.waitForExistence(timeout: 3))
        for _ in 0..<3 where !organize.isHittable {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(organize.isHittable)
        if organize.value as? String == "1" {
            organize.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(organize.value as? String, "0")
        organize.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: organize
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 2), .completed)

        app.buttons["BackButton"].tap()
        let sessionsTab = app.buttons["tab.sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 2))
        sessionsTab.tap()
        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["bighelp"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Travel Planning"].exists)
        XCTAssertTrue(app.staticTexts["Unassigned"].exists)

        let workspaceMenu = app.buttons["home.drawer.open"]
        XCTAssertTrue(workspaceMenu.waitForExistence(timeout: 3))
        workspaceMenu.tap()

        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "navigation.menu").count,
            1
        )
        XCTAssertTrue(app.staticTexts["bighelp"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Travel Planning"].exists)
        XCTAssertTrue(app.staticTexts["Unassigned"].exists)
    }

    @MainActor
    func testV2SkillsWizardCreatesThenEditsTheNewSkill() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.appearance.ui-v2-enabled", "YES"]
        app.launch()
        openSkillsAndTools(in: app)
        let add = app.buttons["skills-tools.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 4))
        let catalogShot = XCTAttachment(screenshot: app.screenshot())
        catalogShot.name = "ui-v2-skills-catalog"
        catalogShot.lifetime = .keepAlways
        self.add(catalogShot)
        add.tap()
        app.buttons["Create with wizard"].tap()
        let name = app.textFields["skills-tools.wizard.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        name.tap(); name.typeText("native-v2-proof")
        let description = app.textFields["When should this skill be used?"]
        description.tap(); description.typeText("Use for native verification.")
        let instructions = app.textViews["skills-tools.wizard.instructions"]
        instructions.tap(); instructions.typeText("Read the source and report facts.")
        let create = app.buttons["skills-tools.wizard.create"]
        XCTAssertTrue(create.isEnabled)
        create.tap()
        let editor = app.textViews["skills-tools.editor.content"]
        if !editor.waitForExistence(timeout: 1) {
            let created = app.buttons["skills-tools.v2.skill:native-v2-proof"]
            XCTAssertTrue(created.waitForExistence(timeout: 5))
            created.tap()
            let edit = app.buttons["Edit SKILL.md"]
            XCTAssertTrue(edit.waitForExistence(timeout: 3))
            edit.tap()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        XCTAssertTrue((editor.value as? String ?? "").contains("native-v2-proof"))
        let editorShot = XCTAttachment(screenshot: app.screenshot())
        editorShot.name = "ui-v2-skills-editor"
        editorShot.lifetime = .keepAlways
        self.add(editorShot)
    }

    @MainActor
    func testSkillsAndToolsOpensEditorAndCreationWizard() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        openSkillsAndTools(in: app)

        XCTAssertTrue(
            app.descendants(matching: .any)["skills-tools.screen"].waitForExistence(timeout: 3)
        )
        let add = app.buttons["skills-tools.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let create = app.buttons["Create with wizard"]
        XCTAssertTrue(create.waitForExistence(timeout: 2))
        create.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["skills-tools.wizard"].waitForExistence(timeout: 3)
        )
        app.buttons["Cancel"].tap()

        let weather = app.buttons["skills-tools.v2.skill:weather"]
        XCTAssertTrue(weather.waitForExistence(timeout: 3))
        weather.tap()
        let edit = app.buttons["Edit SKILL.md"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["skills-tools.editor"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.textViews["skills-tools.editor.content"].exists)
        XCTAssertFalse(app.buttons["skills-tools.editor.save"].isEnabled)
    }

    @MainActor
    func testSessionsSearchCanBeClearedAndResetsAfterLeavingTheScreen() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["tab.sessions"].tap()
        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))
        let search = app.searchFields["sessions.search"]
        XCTAssertTrue(revealSearchField(search, in: app))

        search.tap()
        search.typeText("Finance")
        XCTAssertTrue(app.staticTexts["Finance"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Travel"].exists)

        let clearSearch = app.buttons["sessions.search.clear"]
        XCTAssertTrue(clearSearch.waitForExistence(timeout: 2))
        XCTAssertEqual(clearSearch.label, "Clear search")
        clearSearch.tap()
        XCTAssertTrue(app.staticTexts["Travel"].waitForExistence(timeout: 2))
        XCTAssertFalse(clearSearch.exists)

        search.typeText("Travel")
        search.typeText("\n")
        openActivity(in: app)
        openSidebarDestination("menu.chats", in: app)

        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))
        XCTAssertEqual(search.value as? String, "Search chats")
        XCTAssertTrue(app.staticTexts["Finance"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Travel"].exists)
        XCTAssertFalse(clearSearch.exists)
    }

    @MainActor
    func testHomeWeatherSummaryIsCondensedCenteredAndAboveSignals() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let weather = app.descendants(matching: .any).matching(
            identifier: "dashboard.weather"
        )
        let inboxHeader = app.staticTexts["Agent Inbox"]
        XCTAssertTrue(weather.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(inboxHeader.exists)
        let weatherFrame = (0..<weather.count).reduce(CGRect.null) { frame, index in
            frame.union(weather.element(boundBy: index).frame)
        }
        // V3 fills the dashboard's twenty-point horizontal content insets.
        XCTAssertEqual(weatherFrame.width, app.frame.width - 40, accuracy: 2)
        XCTAssertEqual(weatherFrame.midX, app.frame.midX, accuracy: 2)
        XCTAssertLessThan(weatherFrame.maxY, inboxHeader.frame.minY)
    }

    @MainActor
    func testHomeSignalsExposeManagementActions() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        XCTAssertTrue(app.scrollViews["dashboard.screen"].waitForExistence(timeout: 3))
        for identifier in [
            "dashboard.update.manage.inbox-finance-payment",
            "dashboard.attention.manage.attention-payment",
            "dashboard.attention.clear",
        ] {
            let control = app.buttons[identifier]
            for _ in 0..<8 where !control.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(control.isHittable, identifier)
        }

        XCTAssertFalse(
            app.buttons["dashboard.inbox.clear"].exists,
            "Agent Inbox must not expose a bulk destructive control under its cards."
        )

        let inboxMenu = app.buttons["dashboard.update.manage.inbox-finance-payment"]
        inboxMenu.tap()
        for title in ["Mark read", "Pin", "Start a chat about this", "Delete"] {
            XCTAssertTrue(
                app.buttons[title].waitForExistence(timeout: 2),
                "Agent Inbox overflow menu is missing \(title)."
            )
        }
        XCTAssertFalse(app.buttons["Remove"].exists)
    }

    @MainActor
    func testInboxUpdateOpensFullReadableCanvas() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let row = app.buttons["dashboard.update.row.inbox-finance-payment"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard.update.canvas.inbox-finance-payment"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.staticTexts["dashboard.update.canvas.title"].label,
            "Vendor payment is ready for review"
        )
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.update.canvas.content"].exists)
        XCTAssertTrue(app.buttons["dashboard.update.canvas.start-chat"].exists)
        XCTAssertTrue(app.buttons["dashboard.update.canvas.delete"].exists)
    }

    @MainActor
    func testHomeRowsSupportSwipeToRemoveAcrossBothSignalSections() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let dashboard = app.scrollViews["dashboard.screen"]
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))

        let update = app.buttons["dashboard.update.row.inbox-finance-payment"].firstMatch
        XCTAssertTrue(update.waitForExistence(timeout: 3))
        update.swipeLeft()
        XCTAssertTrue(
            dashboard.waitForExistence(timeout: 1),
            "Removing an update must not open its linked chat."
        )
        XCTAssertFalse(update.waitForExistence(timeout: 1))

        app.terminate()
        app.launch()
        let refreshedDashboard = app.scrollViews["dashboard.screen"]
        XCTAssertTrue(refreshedDashboard.waitForExistence(timeout: 3))
        for _ in 0..<6 {
            let attention = app.buttons["dashboard.attention.row.attention-payment"].firstMatch
            if attention.isHittable { break }
            refreshedDashboard.swipeUp()
        }
        let attention = app.buttons["dashboard.attention.row.attention-payment"].firstMatch
        XCTAssertTrue(attention.isHittable)
        attention.swipeLeft()
        XCTAssertTrue(
            refreshedDashboard.waitForExistence(timeout: 1),
            "Removing a Needs You row must keep Home visible."
        )
        XCTAssertFalse(attention.waitForExistence(timeout: 1))
    }

    @MainActor
    func testChatHidesTheAttachedPrimaryNavigationBar() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()

        XCTAssertTrue(
            messageComposer(in: app).waitForExistence(timeout: 3),
            "The chat canvas did not open from the attached New chat action."
        )
        XCTAssertEqual(
            app.otherElements.matching(identifier: "primary-navigation").count,
            0,
            "Chat owns New Chat in its header and must hide the duplicate bottom navigation."
        )
    }

    @MainActor
    func testChatTimelineReservesTheComposerWithoutDuplicateBottomNavigation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let timeline = app.tables["chat.timeline"]
        let composer = messageComposer(in: app)
        let finalContent = app.staticTexts["Weekly wrap-up"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
        XCTAssertTrue(finalContent.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            finalContent.frame.maxY,
            composer.frame.minY,
            "The final chat content must remain above the attached composer."
        )
        XCTAssertGreaterThanOrEqual(
            composer.frame.minY - finalContent.frame.maxY,
            62,
            "The bottom anchor must leave the original breathing room plus 30 points above the composer."
        )
    }

    @MainActor
    func testMarkdownHierarchyAndRhythmInLightAndDarkAppearances() throws {
        let source = "# Heading One\n\nFirst paragraph with a [link](https://example.com).\n\nSecond paragraph.\n\n## Heading Two\n\n- List item\n\n### Heading Three\n\n> A supporting quote.\n\n```swift\nlet value = 1\n```"
        let visibleText = "Heading One\n\nFirst paragraph with a link.\n\nSecond paragraph.\n\nHeading Two\n\nList item\n\nHeading Three\n\nA supporting quote.\n\nlet value = 1"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "phone"
        let proofDirectory = URL(fileURLWithPath: "/private/tmp/loopdy-release1-evidence/ui-\(device)", isDirectory: true)
        try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
        defer { XCUIDevice.shared.appearance = .light }

        for mode in ["light", "dark"] {
            XCUIDevice.shared.appearance = mode == "dark" ? .dark : .light
            let app = makeApp()
            app.launchArguments = [
                "-use-demo-fixtures", "-start-chat", "-preview-ui-v3", "-disable-demo-delays",
                "-loopdy.demo.appearance", mode,
            ]
            app.launch()
            let composer = messageComposer(in: app)
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            clearComposer(composer)
            composer.typeText(source)
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertTrue(send.isEnabled)
            send.tap()
            let renderedMessage = app.staticTexts.matching(
                NSPredicate(format: "label == %@", "You: \(visibleText)")
            ).firstMatch
            XCTAssertTrue(renderedMessage.waitForExistence(timeout: 5),
                          "Representative Markdown must remain accessible as readable plain text.")
            try app.screenshot().pngRepresentation.write(
                to: proofDirectory.appendingPathComponent("chat-markdown-\(mode).png"), options: .atomic
            )
            app.terminate()
        }
    }

    @MainActor
    func testReturnToLatestTracksBottomAnchorVisibilityAndReturnsToBottom() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let timeline = app.tables["chat.timeline"]
        let returnToLatest = app.buttons["Return to latest messages"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        XCTAssertFalse(returnToLatest.exists, "The bottom anchor must start without the control.")

        let fixtureRunway = messageComposer(in: app)
        XCTAssertTrue(fixtureRunway.waitForExistence(timeout: 3))
        fixtureRunway.tap()
        fixtureRunway.typeText(
            "Create deterministic scroll runway for return-to-latest acceptance by keeping this fixture message long enough to move the bottom anchor outside the visible chat canvas."
        )
        app.buttons["chat.send"].tap()
        let expandedTimeline = NSPredicate(
            format: "value == %@",
            "4 conversation entries"
        )
        expectation(for: expandedTimeline, evaluatedWith: timeline)
        waitForExpectations(timeout: 3)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "The expanded fixture must settle at the bottom before measuring scroll distance."
        )
        XCTAssertFalse(returnToLatest.exists, "Fixture expansion must preserve the bottom anchor.")

        func dragTimeline(by verticalDistance: CGFloat) {
            let start = timeline.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)
            )
            start.press(
                forDuration: 0.1,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: verticalDistance)),
                withVelocity: .slow,
                thenHoldForDuration: 0.1
            )
        }

        for _ in 0..<4 where !returnToLatest.exists {
            dragTimeline(by: 96)
        }
        XCTAssertTrue(
            returnToLatest.waitForExistence(timeout: 1),
            "Return to Latest must appear once bounded upward scrolling moves the bottom anchor outside the visible chat canvas."
        )

        returnToLatest.tap()
        XCTAssertFalse(
            returnToLatest.waitForExistence(timeout: 0.6),
            "Return to Latest must clear as soon as it scrolls to the bottom anchor."
        )

        dragTimeline(by: -80)
        XCTAssertFalse(
            returnToLatest.waitForExistence(timeout: 0.6),
            "Downward overscroll below the bottom anchor must never show the control."
        )

        chatNewChatButton(in: app).tap(); confirmNewChatPicker(in: app)
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(
            returnToLatest.exists,
            "A short new timeline must reset and keep Return to Latest hidden."
        )
    }

    @MainActor
    func testNewChatRestoresBottomAnchorAfterPriorTimelineReleasedFollow() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let priorTimeline = app.tables["chat.timeline"]
        XCTAssertTrue(priorTimeline.waitForExistence(timeout: 3))
        priorTimeline.swipeDown()

        let newChat = chatNewChatButton(in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        let message = "New canvas anchor check"
        composer.tap()
        composer.typeText(message)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.tap()

        let humanMessage = app.staticTexts["You: \(message)"]
        let composerShell = app.otherElements["chat.composer-shell"]
        XCTAssertTrue(humanMessage.waitForExistence(timeout: 3))
        XCTAssertTrue(composerShell.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            humanMessage.frame.maxY,
            composerShell.frame.minY,
            "A new conversation must reset bottom-follow before its first message is laid out."
        )
    }

    @MainActor
    func testChatHeaderAndComposerExposeSingleSemanticChrome() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let header = app.otherElements["chat.header-surface"]
        let composerShell = app.otherElements["chat.composer-shell"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(composerShell.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["View Sessions"].exists)

        for identifier in ["chat.back", "chat.session-controls", "chat.new-chat"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists, identifier)
            XCTAssertTrue(
                header.frame.contains(control.frame),
                "\(identifier) must remain inside the semantic chat header."
            )
        }
        XCTAssertFalse(app.buttons["chat.people"].exists, "The chat header must not show the removed Link action.")

        let back = app.buttons["chat.back"]
        let sessionControl = app.buttons["chat.session-controls"]
        let newChat = chatNewChatButton(in: app)
        for control in [back, newChat] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 48, "Header actions need enlarged hit targets.")
            XCTAssertGreaterThanOrEqual(control.frame.height, 48, "Header actions need enlarged hit targets.")
        }
        XCTAssertEqual(back.frame.midY, sessionControl.frame.midY, accuracy: 1)
        XCTAssertEqual(
            newChat.frame.midY,
            sessionControl.frame.midY,
            accuracy: 0.5,
            "V3 header actions and the session control must share a center axis."
        )

        if app.frame.width <= 700 {
            // V3 sizes this capsule to its two-line model/reasoning content,
            // within a 240-point cap and the space between the edge controls.
            XCTAssertGreaterThanOrEqual(
                sessionControl.frame.width,
                44,
                "The phone model and reasoning control must remain a usable hit target."
            )
            XCTAssertLessThanOrEqual(sessionControl.frame.width, 240)
            XCTAssertGreaterThanOrEqual(sessionControl.frame.minX, back.frame.maxX + 8)
            XCTAssertLessThanOrEqual(sessionControl.frame.maxX, newChat.frame.minX - 8)
            XCTAssertTrue(sessionControl.isHittable)
            XCTAssertEqual(
                sessionControl.frame.midX,
                header.frame.midX,
                accuracy: 1,
                "The phone model and reasoning control must sit on the header's geometric center axis."
            )
        }

        let attachment = app.buttons["chat.attachment"]
        let voice = app.buttons["chat.voice"]
        let input = messageComposer(in: app)
        for element in [attachment, voice, input] {
            XCTAssertTrue(element.exists)
            XCTAssertTrue(
                composerShell.frame.contains(element.frame),
                "The attachment, input, and adaptive action must share one composer shell."
            )
        }
        if app.frame.width > 700 {
            XCTAssertLessThanOrEqual(
                app.buttons["chat.back"].frame.minX,
                app.frame.minX + 32,
                "The regular-width back control must stay in the outer leading corner."
            )
            XCTAssertGreaterThanOrEqual(
                chatNewChatButton(in: app).frame.maxX,
                app.frame.maxX - 32,
                "The regular-width New Chat control must stay in the outer trailing corner."
            )
            XCTAssertGreaterThanOrEqual(
                composerShell.frame.height,
                44,
                "The semantic composer shell must cover the native input and control hit targets."
            )
            XCTAssertEqual(
                attachment.frame.midY,
                input.frame.midY,
                accuracy: 1,
                "The iPad attachment action must be vertically centered with the input."
            )
            XCTAssertEqual(
                voice.frame.midY,
                input.frame.midY,
                accuracy: 1,
                "The iPad voice action must be vertically centered with the input."
            )
        }
        let headerScreenshot = XCTAttachment(screenshot: app.screenshot())
        headerScreenshot.name = "chat-header-normal-\(Int(app.frame.width))x\(Int(app.frame.height))-back-\(back.frame)-session-\(sessionControl.frame)-new-chat-\(newChat.frame)"
        headerScreenshot.lifetime = .keepAlways
        add(headerScreenshot)
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
    }

    @MainActor
    func testChatHeaderKeepsSharedCenterAxisAtAccessibilityXXXL() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-start-chat",
            "-test-session-model",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        let header = app.otherElements["chat.header-surface"]
        let back = app.buttons["chat.back"]
        let sessionControl = app.buttons["chat.session-controls"]
        let newChat = chatNewChatButton(in: app)

        for element in [header, back, sessionControl, newChat] {
            XCTAssertTrue(element.waitForExistence(timeout: 3))
        }
        for control in [back, sessionControl, newChat] {
            XCTAssertTrue(
                header.frame.contains(control.frame),
                "Every primary control must remain inside the semantic header at accessibility XXXL."
            )
        }
        for control in [back, newChat] {
            XCTAssertGreaterThanOrEqual(control.frame.width, 48)
            XCTAssertGreaterThanOrEqual(control.frame.height, 48)
        }
        XCTAssertEqual(back.frame.midY, sessionControl.frame.midY, accuracy: 0.5)
        XCTAssertEqual(newChat.frame.midY, sessionControl.frame.midY, accuracy: 0.5)
        XCTAssertTrue((sessionControl.value as? String)?.contains("session-chosen-model") == true)

        let longNameScreenshot = XCTAttachment(screenshot: app.screenshot())
        longNameScreenshot.name = "chat-header-accessibility-xxxl-long-model-\(Int(app.frame.width))x\(Int(app.frame.height))-back-\(back.frame)-session-\(sessionControl.frame)-new-chat-\(newChat.frame)"
        longNameScreenshot.lifetime = .keepAlways
        add(longNameScreenshot)

        sessionControl.tap()
        let seeAll = app.buttons["chat.models.see-all"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 3))
        seeAll.tap()
        let search = app.searchFields["Search providers and models"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("gpt-5.6")
        let shortModel = app.buttons["model-picker.openai.gpt-5.6"]
        XCTAssertTrue(shortModel.waitForExistence(timeout: 3))
        shortModel.tap()
        let reasoning = app.descendants(matching: .any)["model-picker.reasoning-slider"].firstMatch
        XCTAssertTrue(reasoning.waitForExistence(timeout: 3))
        XCTAssertTrue(reasoning.isHittable)
        reasoning.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65)).press(forDuration: 0.1,
            thenDragTo: reasoning.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)))
        XCTAssertTrue(reasoning.isHittable)
        let apply = app.buttons["model-picker.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        apply.tap()
        let shortModelApplied = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "gpt-5.6"),
            object: sessionControl
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [shortModelApplied], timeout: 3),
            .completed,
            "Applying the short fixture model must update the header control."
        )
        XCTAssertEqual(back.frame.midY, sessionControl.frame.midY, accuracy: 0.5)
        XCTAssertEqual(newChat.frame.midY, sessionControl.frame.midY, accuracy: 0.5)

        let shortNameScreenshot = XCTAttachment(screenshot: app.screenshot())
        shortNameScreenshot.name = "chat-header-accessibility-xxxl-short-model-\(Int(app.frame.width))x\(Int(app.frame.height))-back-\(back.frame)-session-\(sessionControl.frame)-new-chat-\(newChat.frame)"
        shortNameScreenshot.lifetime = .keepAlways
        add(shortNameScreenshot)
    }

    @MainActor
    func testTypingSlashShowsTheSessionCommandMenu() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        clearComposer(composer)
        composer.typeText("/")

        let commandAppeared = app.buttons["reference-hub.command.help"].waitForExistence(timeout: 3)
        if !commandAppeared {
            print(app.debugDescription)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(
            commandAppeared,
            "Typing / must open the dynamically filtered command menu above the composer."
        )
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Slash suggestions must not dismiss the keyboard.")
        composer.typeText("help")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Recognizing an exact command must preserve the keyboard.")
        let help = app.buttons["reference-hub.command.help"]
        XCTAssertTrue(help.exists)
        help.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Command selection must preserve the keyboard.")
        XCTAssertTrue(app.otherElements["reference-hub.drawer"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Selecting the command token must preserve the keyboard.")
        let argumentField = messageComposer(in: app)
        XCTAssertEqual(argumentField.value as? String, "/help ")
        argumentField.typeText("details")
        XCTAssertEqual(argumentField.value as? String, "/help details")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    @MainActor
    func testShellChromeReservesTopAndBottomLayoutSpace() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let workspaceMenu = app.buttons["home.drawer.open"]
        let rootTitle = app.staticTexts["loopdy.root.title"]
        let navigation = app.otherElements["primary-navigation"]
        let dashboard = app.scrollViews["sessions.screen"]
        XCTAssertTrue(workspaceMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(rootTitle.waitForExistence(timeout: 3))
        XCTAssertTrue(navigation.waitForExistence(timeout: 3))
        XCTAssertTrue(dashboard.waitForExistence(timeout: 3))

        XCTAssertGreaterThanOrEqual(
            rootTitle.frame.minY,
            workspaceMenu.frame.maxY,
            "The workspace header must reserve layout space above screen content."
        )
        // The glass itself is inset on phones and centered at a bounded width on tablets.
        let expectedWidth = min(app.frame.width - 24, 620)
        XCTAssertEqual(navigation.frame.width, expectedWidth, accuracy: 1)
        XCTAssertEqual(navigation.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(navigation.frame.minX, app.frame.minX + 12)
        XCTAssertLessThanOrEqual(navigation.frame.maxY, app.frame.maxY)
        for identifier in ["tab.agents", "tab.sessions", "tab.scheduled-tasks", "tab.workspace", "root.new-chat"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, identifier)
            XCTAssertTrue(navigation.frame.contains(control.frame), identifier)
        }
        XCTAssertGreaterThan(
            dashboard.frame.maxY,
            navigation.frame.minY,
            "The root scroll viewport must extend behind the glass, not end above a sibling bar."
        )
        // The final demo completion must still scroll completely above the reserved inset.
        let lastCompletion = app.buttons["session.row.demo-session-48"]
        for _ in 0..<40 {
            if lastCompletion.exists && lastCompletion.isHittable
                && lastCompletion.frame.maxY <= navigation.frame.minY { break }
            dashboard.swipeUp()
        }
        XCTAssertTrue(lastCompletion.exists)
        XCTAssertTrue(lastCompletion.isHittable)
        XCTAssertLessThanOrEqual(lastCompletion.frame.maxY, navigation.frame.minY)
    }

    @MainActor
    func testLiveBighelpLinkRoundTrip() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIGHELP_LIVE_SMOKE"] == "1"
                || environment["TEST_RUNNER_BIGHELP_LIVE_SMOKE"] == "1"
        else {
            throw XCTSkip("Run explicitly against a paired production bighelp Link account.")
        }

        let app = makeApp()
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8), "New chat is unavailable.")
        newChat.tap()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "Chat composer is unavailable.")

        let suffix = String(Int(Date().timeIntervalSince1970) % 1_000_000)
        let expectedReply = "BIGHELPLINKSMOKE\(suffix)"
        let request = "Reply with exactly these chunks joined with no spaces: BIGHELP, LINK, SMOKE, \(suffix)."

        composer.tap()
        composer.typeText(request)

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send is unavailable.")
        XCTAssertTrue(send.isEnabled, "Send never became enabled.")
        send.tap()

        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expectedReply)
        ).firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 90),
            "No streamed bighelp Link reply contained \(expectedReply)."
        )
        let timestamp = app.staticTexts.matching(
            identifier: "timeline-message-timestamp"
        ).firstMatch
        XCTAssertTrue(
            timestamp.waitForExistence(timeout: 5),
            "The final reply did not retain its local arrival date and time."
        )
        XCTAssertFalse(timestamp.label.contains("Source:"))
    }

    @MainActor
    func testLiveChatWorkflowLoadsIdentityControlsSlashCommandsAndQuickWorkspace() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIGHELP_LIVE_SMOKE"] == "1"
                || environment["TEST_RUNNER_BIGHELP_LIVE_SMOKE"] == "1"
        else {
            throw XCTSkip("Run explicitly against a paired production bighelp Link account.")
        }

        let app = makeApp()
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8), "New chat is unavailable.")
        newChat.tap()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "Chat composer is unavailable.")

        let agentName = app.staticTexts["Juno"]
        guard agentName.waitForExistence(timeout: 15) else {
            XCTFail("The active chat did not show the remote agent name Juno.")
            return
        }

        let controls = app.buttons["chat.session-controls"]
        guard controls.waitForExistence(timeout: 8) else {
            XCTFail("Session model controls are unavailable.")
            return
        }
        controls.tap()
        let recentModels = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.quick-model.")
        )
        guard recentModels.count > 0 else {
            XCTFail("The session picker did not load recent model choices.")
            return
        }
        recentModels.firstMatch.tap()
        let reasoning = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.reasoning.")
        ).firstMatch
        guard reasoning.waitForExistence(timeout: 15) else {
            XCTFail("Choosing a model did not load its reasoning choices.")
            return
        }
        let pickerControls = app.buttons["chat.session-controls"]
        pickerControls.tap()
        guard reasoning.waitForNonExistence(timeout: 5) else {
            XCTFail("The session picker did not dismiss before slash-command entry.")
            return
        }
        let chatComposer = messageComposer(in: app)
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 8))
        chatComposer.tap()
        clearComposer(chatComposer)
        chatComposer.typeText("/")
        let slashMenu = app.scrollViews["chat.slash-command-menu"]
        guard slashMenu.waitForExistence(timeout: 15) else {
            XCTFail("Typing / did not load the Hermes slash-command menu.")
            return
        }
        // Re-resolve after the suggestions appear: the UIKit-backed composer
        // can be reclassified by XCTest when SwiftUI inserts the menu.
        let filteredComposer = messageComposer(in: app)
        XCTAssertTrue(filteredComposer.waitForExistence(timeout: 5))
        filteredComposer.tap()
        filteredComposer.typeText("help")

        // The composer combines the selected command chip with the input
        // into one accessibility element (labelled Message); the invocation
        // remains exposed as its value.
        let selectedHelp = app.buttons.matching(
            NSPredicate(format: "value == %@", "/help")
        ).firstMatch
        guard selectedHelp.waitForExistence(timeout: 5) else {
            XCTFail("Finishing the valid /help command did not promote it to the composer command token.")
            return
        }
        XCTAssertTrue(
            app.buttons["chat.send"].waitForExistence(timeout: 5),
            "The selected /help command did not expose the send action."
        )
        app.buttons["chat.send"].tap()

        let helpResponse = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Available Commands")
        ).firstMatch
        XCTAssertTrue(
            helpResponse.waitForExistence(timeout: 60),
            "Executing /help did not produce a streamed Hermes command response."
        )

        let suffix = String(Int(Date().timeIntervalSince1970) % 1_000_000)
        let expectedReply = "BIGHELPWORKFLOW\(suffix)"
        let request = "Reply with exactly these chunks joined with no spaces: BIGHELP, WORKFLOW, \(suffix)."
        let replyComposer = messageComposer(in: app)
        XCTAssertTrue(replyComposer.waitForExistence(timeout: 8))
        replyComposer.tap()
        replyComposer.typeText(request)

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send is unavailable.")
        XCTAssertTrue(send.isEnabled, "Send never became enabled.")
        send.tap()

        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expectedReply)
        ).firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 120),
            "No streamed bighelp Link reply contained \(expectedReply)."
        )

        openChatWorkspaceMenu(in: app)
        let currentSession = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu.chat.")
        ).firstMatch
        XCTAssertTrue(
            currentSession.waitForExistence(timeout: 10),
            "The completed session did not appear in the Quick Workspace recent sessions."
        )
    }

    @MainActor
    func testLiveReopenedSessionRendersCanonicalTranscriptAndAgentIdentity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIGHELP_LIVE_SMOKE"] == "1"
                || environment["TEST_RUNNER_BIGHELP_LIVE_SMOKE"] == "1"
        else {
            throw XCTSkip("Run explicitly against a paired production bighelp Link account.")
        }

        let app = makeApp()
        app.launch()

        let workspaceMenu = app.buttons["home.drawer.open"]
        XCTAssertTrue(
            workspaceMenu.waitForExistence(timeout: 8),
            "The dashboard did not expose the Quick Workspace menu."
        )
        workspaceMenu.tap()
        let sessionsLink = app.buttons["menu.chats"]
        XCTAssertTrue(
            sessionsLink.waitForExistence(timeout: 8),
            "Quick Workspace did not expose the Sessions entry point."
        )
        sessionsLink.tap()

        XCTAssertTrue(
            app.scrollViews["sessions.screen"].waitForExistence(timeout: 15),
            "The live Sessions screen did not load."
        )
        let sessionRows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "session.row.")
        )
        XCTAssertTrue(
            sessionRows.firstMatch.waitForExistence(timeout: 20),
            "The live Sessions screen contained no durable sessions."
        )
        // The paired account has durable weather sessions created by the live
        // tool round-trip. Selecting one makes this proof cover both ordinary
        // assistant transcript rows and persisted tool activity, rather than
        // only the one-line session preview.
        let weatherRows = sessionRows.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "weather")
        )
        XCTAssertTrue(
            weatherRows.firstMatch.waitForExistence(timeout: 20),
            "The live Sessions screen contained no durable tool-backed weather session."
        )
        let selectedRow = weatherRows.firstMatch
        let summaryLabel = selectedRow.label
        selectedRow.tap()

        XCTAssertTrue(
            messageComposer(in: app).waitForExistence(timeout: 15),
            "The selected live session could not be reopened."
        )
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 8), "The reopened chat canvas is unavailable.")

        let humanRows = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "You:")
        )
        XCTAssertTrue(
            humanRows.firstMatch.waitForExistence(timeout: 15),
            "The reopened session did not render its canonical human turn. Session summary: \(summaryLabel)"
        )
        let assistantRows = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH[c] %@", "Juno:")
        )
        XCTAssertTrue(
            assistantRows.firstMatch.waitForExistence(timeout: 15),
            "The reopened session did not render Juno's canonical assistant turn. Session summary: \(summaryLabel)"
        )
        XCTAssertTrue(
            humanRows.allElementsBoundByIndex.allSatisfy { row in
                let prefix = "You:"
                return row.label.hasPrefix(prefix)
                    && !row.label.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            },
            "Every restored human row must have non-empty visible content. Session summary: \(summaryLabel)"
        )
        XCTAssertTrue(
            assistantRows.allElementsBoundByIndex.allSatisfy { row in
                let prefix = "Juno:"
                return row.label.hasPrefix(prefix)
                    && !row.label.dropFirst(prefix.count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
            },
            "Every restored assistant row must have non-empty visible content. Session summary: \(summaryLabel)"
        )

        let workTrail = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")
        ).firstMatch
        guard workTrail.waitForExistence(timeout: 15) else {
            XCTFail(
                "The reopened session did not retain its persisted tool activity. Session summary: \(summaryLabel)"
            )
            return
        }
        workTrail.tap()
        let activity = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
        ).firstMatch
        XCTAssertTrue(
            activity.waitForExistence(timeout: 15),
            "The reopened session did not expose the persisted tool activity details. Session summary: \(summaryLabel)"
        )
        let navigation = app.otherElements["primary-navigation"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            activity.frame.maxY,
            navigation.frame.minY,
            "Expanded work-trail details must remain above the attached composer/navigation inset."
        )

    }

    @MainActor
    func testLiveBighelpLinkWeatherToolActivityStaysVisibleInChat() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BIGHELP_LIVE_SMOKE"] == "1"
                || environment["TEST_RUNNER_BIGHELP_LIVE_SMOKE"] == "1"
        else {
            throw XCTSkip("Run explicitly against a paired production bighelp Link account.")
        }

        let app = makeApp()
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 8), "New chat is unavailable.")
        newChat.tap()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 8), "Chat composer is unavailable.")

        let suffix = String(Int(Date().timeIntervalSince1970) % 1_000_000)
        let expectedReply = "BIGHELPWEATHER\(suffix)"
        let request = "Check the current weather in Chicago and render it as bighelp's "
            + "native weather forecast card by calling bighelp_render_weather_forecast. "
            + "After the card is sent, reply with exactly \(expectedReply)."

        composer.tap()
        composer.typeText(request)

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send is unavailable.")
        XCTAssertTrue(send.isEnabled, "Send never became enabled.")
        send.tap()

        let working = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "working")
        ).firstMatch
        XCTAssertTrue(
            working.waitForExistence(timeout: 10),
            "The active chat never showed the agent working state."
        )

        let workTrail = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")
        ).firstMatch
        guard workTrail.waitForExistence(timeout: 30) else {
            XCTFail("The tool activity never reached the open chat canvas.")
            return
        }

        let workTrailToggle = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")
        ).firstMatch
        guard workTrailToggle.waitForExistence(timeout: 3) else {
            XCTFail("The streamed work trail was not expandable.")
            return
        }
        workTrailToggle.tap()

        let activity = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
        ).firstMatch
        if !activity.waitForExistence(timeout: 3) {
            let visibility = app.buttons["Work trail visibility"]
            XCTAssertTrue(
                visibility.waitForExistence(timeout: 3),
                "The work-trail visibility control was unavailable."
            )
            visibility.tap()
            let showToolCalls = app.buttons["Show tool calls"]
            if !showToolCalls.waitForExistence(timeout: 2) {
                let hideToolCalls = app.buttons["Hide tool calls"]
                XCTAssertTrue(
                    hideToolCalls.waitForExistence(timeout: 2),
                    "The tool-call visibility option was unavailable."
                )
                hideToolCalls.tap()
                visibility.tap()
                XCTAssertTrue(
                    showToolCalls.waitForExistence(timeout: 2),
                    "The tool-call visibility option did not switch to show."
                )
            }
            showToolCalls.tap()
        }
        XCTAssertTrue(
            activity.waitForExistence(timeout: 10),
            "The tool activity detail was not visible in the open chat."
        )

        let weatherCard = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier == %@",
                "chat.generative-ui.weather_forecast"
            )
        ).firstMatch
        XCTAssertTrue(
            weatherCard.waitForExistence(timeout: 180),
            "Hermes never rendered the bighelp weather card in the active chat."
        )

        let source = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "National Weather Service")
        ).firstMatch
        XCTAssertTrue(
            source.waitForExistence(timeout: 180),
            "The weather card did not show National Weather Service provenance."
        )
        let reply = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", expectedReply)
        ).firstMatch
        XCTAssertTrue(
            reply.waitForExistence(timeout: 30),
            "No finalized weather reply contained \(expectedReply)."
        )

        XCTAssertTrue(
            working.waitForNonExistence(timeout: 10),
            "The working indicator remained after the final response."
        )
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Message could not be delivered")
            ).firstMatch.exists,
            "The open chat reported a delivery failure despite receiving the final response."
        )
    }

    @MainActor
    func testLaunchShowsRootTitle() throws {
        let app = makeApp()
        // The production launch is intentionally gated until the account, paired
        // host, and verified Link connection are ready. Use the deterministic
        // in-process fixtures for this shell smoke assertion instead of relying
        // on whatever account state happens to be on the test simulator.
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        XCTAssertTrue(app.staticTexts["loopdy.root.title"].waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.buttons["dashboard.sessions"].exists,
            "Home must not render a standalone Sessions shortcut."
        )
    }

    @MainActor
    func testTopRightNewChatReplacesDraftedConversation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let shellNewChat = app.buttons["root.new-chat"]
        XCTAssertTrue(shellNewChat.waitForExistence(timeout: 3))
        shellNewChat.tap()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("Draft that belongs to the first chat")
        XCTAssertEqual(composer.value as? String, "Draft that belongs to the first chat")

        let headerNewChat = chatNewChatButton(in: app)
        XCTAssertTrue(headerNewChat.exists)
        headerNewChat.tap()

        let replacementComposer = messageComposer(in: app)
        XCTAssertTrue(replacementComposer.waitForExistence(timeout: 3))
        XCTAssertNotEqual(
            replacementComposer.value as? String,
            "Draft that belongs to the first chat"
        )
    }

    @MainActor
    func testChatHidesBottomNavigationAndKeepsHeaderNewChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let shellNewChat = app.buttons["root.new-chat"]
        XCTAssertTrue(shellNewChat.waitForExistence(timeout: 3))
        shellNewChat.tap()
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.otherElements["primary-navigation"].exists,
            "Chat owns its New Chat action and must not duplicate it in bottom navigation."
        )
        XCTAssertTrue(chatNewChatButton(in: app).exists)
    }

    @MainActor
    func testChatHamburgerPresentsWorkspaceWithRecentSessionsAndFullSessionsRoute() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let shellNewChat = app.buttons["root.new-chat"]
        XCTAssertTrue(shellNewChat.waitForExistence(timeout: 3))
        shellNewChat.tap()

        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 3))
        openChatWorkspaceMenu(in: app)

        XCTAssertTrue(
            app.buttons["menu.chats"].waitForExistence(timeout: 2),
            "The workspace drawer must render above the active chat with a Sessions route."
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "navigation.menu").count,
            1,
            "Quick Workspace must expose one accessibility container for the drawer."
        )
        XCTAssertTrue(
            app.buttons["quick-workspace.backdrop"].exists,
            "The active chat must be covered by the dismissible blurred backdrop."
        )
        XCTAssertGreaterThan(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "menu.chat.")
        ).count, 0)
    }

    @MainActor
    func testHamburgerPresentsSharedWorkspaceFromEveryRootTab() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 3))

        let tabsAndDrawerActions = [
            (tabID: "tab.agents", drawerActionID: "menu.agents"),
            (tabID: "tab.sessions", drawerActionID: "menu.chats"),
            (tabID: "tab.scheduled-tasks", drawerActionID: "menu.scheduled-tasks"),
            (tabID: "tab.workspace", drawerActionID: "menu.settings"),
        ]

        XCTAssertFalse(app.buttons["tab.inbox"].exists)

        for (tabID, drawerActionID) in tabsAndDrawerActions {
            let tab = app.buttons[tabID]
            XCTAssertTrue(tab.waitForExistence(timeout: 3), "Missing root tab: \(tabID)")
            tab.tap()

            let menu = app.buttons["home.drawer.open"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3), "Missing workspace menu on \(tabID)")
            menu.tap()
            XCTAssertTrue(
                app.buttons["menu.chats"].waitForExistence(timeout: 3),
                "Shared workspace drawer did not open from \(tabID)."
            )
            let drawerAction = app.buttons[drawerActionID]
            XCTAssertTrue(drawerAction.waitForExistence(timeout: 2), drawerActionID)
            drawerAction.tap()
            openSidebarDestination("menu.chats", in: app)
            XCTAssertTrue(app.buttons["tab.sessions"].isSelected)
        }
    }

    @MainActor
    func testNewChatKeepsEmptyCanvasAndSuggestionsAboveComposer() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()

        let title = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "What can ")
        ).firstMatch
        let suggestion = app.buttons["quick.weather"]
        let composer = app.otherElements["chat.composer-shell"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(title.frame.minY, app.frame.minY)
        for (identifier, text) in [("quick.weather", "Catch me up"), ("quick.budget", "Plan my day"), ("quick.approval", "Start a task")] {
            let prompt = app.buttons[identifier]
            XCTAssertTrue(prompt.staticTexts[text].exists, "Suggested prompts must visibly include their title.")
            XCTAssertGreaterThan(prompt.frame.width, 120)
            XCTAssertLessThan(prompt.frame.height, 80, "A suggested prompt must remain a compact readable control.")
            XCTAssertLessThanOrEqual(prompt.frame.maxY, composer.frame.minY)
        }
        XCTAssertLessThanOrEqual(
            suggestion.frame.maxY,
            composer.frame.minY,
            "The initial suggestions must be fully visible above the composer."
        )
        saveV2Evidence(app, name: "suggested-prompts-compact-text")
    }

    @MainActor
    func testAccessibilityXXXLNewChatSuggestionsKeepTextInsideHittableControls() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()

        let timeline = app.tables["chat.timeline"]
        let composer = app.otherElements["chat.composer-shell"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        for (identifier, text) in [
            ("quick.weather", "Catch me up"),
            ("quick.budget", "Plan my day"),
            ("quick.approval", "Start a task")
        ] {
            let prompt = app.buttons[identifier]
            let title = prompt.staticTexts[text]
            XCTAssertTrue(prompt.waitForExistence(timeout: 3), identifier)
            XCTAssertTrue(title.exists, "Accessibility-sized prompt must keep its visible title.")
            XCTAssertTrue(prompt.isHittable, "Accessibility-sized prompt must remain hittable.")
            XCTAssertGreaterThanOrEqual(prompt.frame.height, 44, identifier)
            XCTAssertGreaterThanOrEqual(prompt.frame.minX, timeline.frame.minX - 1, identifier)
            XCTAssertLessThanOrEqual(prompt.frame.maxX, timeline.frame.maxX + 1, identifier)
            XCTAssertLessThanOrEqual(prompt.frame.maxY, composer.frame.minY + 1, identifier)
        }
        saveV2Evidence(app, name: "suggested-prompts-accessibility-text")
    }

    @MainActor
    func testHamburgerPresentsSharedWorkspaceFromSessionsRootTab() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let sessionsTab = app.buttons["tab.sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 3))
        sessionsTab.tap()

        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(
            menu.waitForExistence(timeout: 3),
            "The Sessions root tab must expose the shared workspace menu."
        )
        menu.tap()

        XCTAssertTrue(
            app.buttons["menu.chats"].waitForExistence(timeout: 3),
            "The Sessions root tab must present the same workspace drawer as every other root tab."
        )
    }

    @MainActor
    func testTappingChatCanvasDismissesKeyboardAndComposerCanBeFocusedAgain() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.isEnabled, "The chat composer must be enabled before editing begins.")
        XCTAssertTrue(composer.isHittable, "The chat composer must be hittable before editing begins.")
        composer.tap()
        composer.typeText("K")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))

        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "Tapping the chat canvas should dismiss the keyboard."
        )

        composer.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 2),
            "Tapping the composer should keep editing available after canvas dismissal."
        )
    }

    @MainActor
    func testChatComposerUsesStablePlainTextInput() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.buttons["chat.composer.format"].exists,
            "The crash-prone attributed-text formatting control must not be exposed."
        )
        composer.tap()
        composer.typeText("Plain **Markdown** stays editable")
        XCTAssertEqual(composer.value as? String, "Plain **Markdown** stays editable")
    }

    @MainActor
    func testCondensedComposerCapsAtFourLinesScrollsAndExpandsWithoutLosingDraft() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        let draft = (1...8).map { "Line \($0)" }.joined(separator: "\n")
        composer.typeText(draft)

        let expand = app.buttons["chat.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            composer.frame.height,
            90,
            "The condensed composer must remain a four-line viewport."
        )
        composer.swipeUp()
        XCTAssertEqual(composer.value as? String, draft)

        expand.tap()
        let expanded = app.textViews["Expanded message"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 3))
        XCTAssertEqual(expanded.value as? String, draft)
    }

    @MainActor
    func testPinchingComposerExpandsAndCollapsesWithoutLosingDraft() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        let composerShell = app.otherElements["chat.composer-shell"]
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(composerShell.waitForExistence(timeout: 3))
        composer.tap()
        let draft = "Pinch keeps this draft intact"
        composer.typeText(draft)

        composerShell.pinch(withScale: 1.8, velocity: 1)
        let expanded = app.textViews["Expanded message"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 3))
        XCTAssertEqual(expanded.value as? String, draft)

        expanded.pinch(withScale: 0.5, velocity: -1)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, draft)
    }

    @MainActor
    func testTappingComposerPaddingFocusesDraftWithoutStealingAttachmentAction() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composerShell = app.otherElements["chat.composer-shell"]
        let composer = messageComposer(in: app)
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(composerShell.waitForExistence(timeout: 3))
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertTrue(attachment.waitForExistence(timeout: 3))

        composerShell.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)
        ).tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 2),
            "Tapping empty padding inside the visible composer must focus its draft field."
        )

        attachment.tap()
        XCTAssertTrue(
            app.buttons["chat.action.photo"].waitForExistence(timeout: 3),
            "The composer focus hit area must not intercept the attachment control."
        )
        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "Opening the attachment drawer should retain its existing keyboard dismissal behavior."
        )
    }

    @MainActor
    func testCachedTranscriptHasNoHydrationOverlay() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-held-session-history"]
        app.launch()
        let sessions = app.buttons["tab.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 5)); sessions.tap()
        let saved = app.buttons["session.row.demo-tool-folder-anchor"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Anchor sentinel stays visible.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 2))
        XCTAssertFalse(app.otherElements["session.restore.loading"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chat.history-loading").firstMatch.exists,
                       "A background refresh must not cover an existing transcript with a second loader.")
        XCTAssertFalse(app.staticTexts["Loading recent messages"].exists)
        XCTAssertTrue(app.staticTexts["Getting the latest changes..."].waitForExistence(timeout: 2),
                      "A small non-blocking status must describe the ongoing refresh.")
        saveV2Evidence(app, name: "cached-transcript-refresh-footer")
    }

    @MainActor
    func testCachedSessionOpenInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try testCachedSessionIsUsableBeforeMetadataAndHistoryReturn()
    }

    @MainActor
    func testDocumentScannerEntryInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        try testDocumentScannerEntryIsVisibleAndSafeOnSimulator()
    }

    @MainActor
    func testDocumentScannerEntryIsVisibleAndSafeOnSimulator() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 5)); attachment.tap()
        let scanner = app.buttons["chat.action.scan-document"]
        XCTAssertTrue(scanner.waitForExistence(timeout: 3))
        XCTAssertTrue(scanner.label.contains("Scan document"))
        #if targetEnvironment(simulator)
        XCTAssertFalse(scanner.isEnabled, "Unsupported hardware must not present the camera scanner.")
        #endif
        saveV2Evidence(app, name: "native-document-scanner-entry")
    }

    @MainActor
    func testCachedSessionIsUsableBeforeMetadataAndHistoryReturn() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-held-session-metadata",
            "-test-held-session-history"]
        app.launch()
        let sessionsTab = app.buttons["tab.sessions"]
        XCTAssertTrue(sessionsTab.waitForExistence(timeout: 5)); sessionsTab.tap()
        let session = app.descendants(matching: .any).matching(identifier: "session.row.demo-finance").firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        let options = app.buttons["chat.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 2), "Opening cached content must not await metadata or history.")
        // A wide landscape window uses an embedded sidebar, not a modal drawer.
        // Assert the actual navigation action after the first visible-target tap.
        // Quick Workspace lives inside the ⋯ menu.
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let workspaceItem = app.buttons["chat.workspace-menu"]
        XCTAssertTrue(workspaceItem.waitForExistence(timeout: 5))
        workspaceItem.tap()
        let chats = app.buttons["quick-workspace.menu.chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 2), "The first tap must open navigation while history is held.")
        app.buttons["menu.done"].tap()
        XCTAssertTrue(chats.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.otherElements["session.restore.loading"].exists)
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 2))
        composer.tap()
        composer.typeText("Draft survives refresh")
        saveV2Evidence(app, name: "cache-first-held-history")
        openChatWorkspaceMenu(in: app)
        // Use the top-level Chats destination. The recent-chat section header
        // can be covered by the drawer's sticky footer in compact landscape.
        let sessions = app.buttons["quick-workspace.menu.chats"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 2)); sessions.tap()
        XCTAssertTrue(app.scrollViews["sessions.screen"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.otherElements["session.restore.loading"].exists)
        let reopened = app.descendants(matching: .any).matching(identifier: "session.row.demo-finance").firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 3)); reopened.tap()
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(String(describing: messageComposer(in: app).value).contains("Draft survives refresh"))
    }

    @MainActor
    func testRestoringIdleChatReturnsToSessionsOnFirstTap() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-held-session-history"]
        app.launch()
        for destination in ["sessions", "home"] {
            if destination == "home" { openActivity(in: app) }
            else { openSidebarDestination("menu.chats", in: app) }
            let session: XCUIElement
            if destination == "home" {
                let rootMenu = app.buttons["home.drawer.open"]
                (rootMenu.exists ? rootMenu : app.buttons["workspace.menu"]).tap()
                session = app.buttons["menu.chat.demo-finance"]
            } else {
                session = app.descendants(matching: .any).matching(identifier: "session.row.demo-finance").firstMatch
            }
            XCTAssertTrue(session.waitForExistence(timeout: 3))
            session.tap()
            let menu = app.buttons["chat.options"]
            XCTAssertTrue(menu.waitForExistence(timeout: 3))
            XCTAssertTrue(menu.isEnabled)
            XCTAssertGreaterThanOrEqual(min(menu.frame.width, menu.frame.height), 44)
            // The native timeline can overlap the header in AX even though
            // UIKit routes its touch correctly. Prove one physical center tap
            // and the resulting destination, not the inferred AX hit flag.
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            // Quick Workspace is the first item inside the ⋯ menu.
            let workspaceItem = app.buttons["chat.workspace-menu"]
            XCTAssertTrue(workspaceItem.waitForExistence(timeout: 5))
            workspaceItem.tap()
            // "home": ☰ › Agents.
            let action = app.buttons[destination == "home" ? "menu.agents" : "menu.chats"]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.tap()
            let arrived = NSPredicate { _, _ in
                (destination == "home" ? app.descendants(matching: .any)["agents.screen"].firstMatch.exists
                    : app.buttons["tab.sessions"].isSelected && app.scrollViews["sessions.screen"].isHittable)
                    && !app.otherElements["session.restore.loading"].exists
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: arrived, object: app)], timeout: 3), .completed)
        }
    }

    @MainActor
    func testV3RootSidebarDestinationsNavigateOnFirstTap() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        for (destination, throughSkills) in [("home", false), ("sessions", false), ("home", true), ("sessions", true)] {
            openSettings(in: app)
            if throughSkills {
                openSkillsAndTools(in: app)
                XCTAssertTrue(app.navigationBars["Skills & Tools"].waitForExistence(timeout: 3))
            }
            let menu = app.buttons["home.drawer.open"].firstMatch
            let nestedMenu = app.buttons["workspace.menu"].firstMatch
            (menu.exists && menu.isHittable ? menu : nestedMenu).tap()
            let identifier = destination == "home" ? "menu.agents" : "menu.chats"  // "home": ☰ › Agents
            let action = app.buttons[identifier]
            XCTAssertTrue(action.waitForExistence(timeout: 3))
            action.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let arrived = NSPredicate { _, _ in
                !app.otherElements["navigation.menu"].exists
                    && (destination == "home" ? app.descendants(matching: .any)["agents.screen"].firstMatch.exists
                        : app.buttons["tab.sessions"].isSelected && app.scrollViews["sessions.screen"].isHittable)
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: arrived, object: app)], timeout: 3), .completed)
        }
    }

    @MainActor
    func testV3ChatSidebarDestinationsNavigateOnFirstTap() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        for origin in ["home", "sessions"] {
            for destination in ["home", "sessions"] {
                if origin == "home" { openActivity(in: app) }
                else { openSidebarDestination("menu.chats", in: app) }
                openSidebarDestination("menu.new-chat", in: app)
                let composer = messageComposer(in: app)
                XCTAssertTrue(composer.waitForExistence(timeout: 3))
                composer.tap()
                messageComposer(in: app).typeText("Retained draft")
                openChatWorkspaceMenu(in: app)
                let identifier = destination == "home" ? "menu.agents" : "menu.chats"  // "home": ☰ › Agents
                let action = app.buttons[identifier]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                action.tap()
                let departed = NSPredicate { _, _ in
                    !app.buttons["chat.options"].exists
                        && !app.otherElements["navigation.menu"].exists
                        && (destination == "home" ? app.descendants(matching: .any)["agents.screen"].firstMatch.exists
                            : app.buttons["tab.sessions"].isHittable && app.buttons["tab.sessions"].isSelected
                                && app.scrollViews["sessions.screen"].isHittable)
                }
                let arrival = XCTNSPredicateExpectation(predicate: departed, object: app)
                let result = XCTWaiter.wait(for: [arrival], timeout: 3)
                if result != .completed {

                    let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    capture.name = "sidebar-\(origin)-\(destination)"
                    capture.lifetime = .keepAlways
                    add(capture)
                }
                XCTAssertEqual(result, .completed)
            }
        }
    }

    @MainActor
    func testV3SendAcceptsOffCenterTaps() throws {
        let points = [CGVector(dx: 0.1, dy: 0.1), CGVector(dx: 0.9, dy: 0.1), CGVector(dx: 0.9, dy: 0.5)]
        for (index, point) in points.enumerated() {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
            app.launch()
            let newChat = app.buttons["root.new-chat"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 3))
            newChat.tap()
            let composer = messageComposer(in: app)
            XCTAssertTrue(composer.waitForExistence(timeout: 3))
            composer.tap()
            let text = "Off center send \(index)"
            messageComposer(in: app).typeText(text)
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertTrue(send.isEnabled)
            XCTAssertGreaterThanOrEqual(send.frame.width, 52)
            XCTAssertGreaterThanOrEqual(send.frame.height, 52)
            send.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(app.staticTexts["You: \(text)"].waitForExistence(timeout: 3), "Send must accept one tap at \(point)")
            app.terminate()
        }
    }

    @MainActor
    func testOpeningWorkspaceAndFollowingDrawerActionDismissesKeyboard() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("D")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))

        openChatWorkspaceMenu(in: app)
        XCTAssertTrue(app.buttons["menu.chats"].waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "Opening Quick Workspace should dismiss the keyboard."
        )

        app.buttons["menu.chats"].tap()
        XCTAssertTrue(
            app.staticTexts["Sessions"].waitForExistence(timeout: 3),
            "The drawer action should leave the chat without restoring the keyboard."
        )
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1))
    }

    @MainActor
    func testSendingMessageDismissesKeyboardImmediately() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        // SwiftUI's vertically growing field may reclassify from TextField to
        // TextView once it becomes first responder. Re-resolve the stable
        // accessibility label before typing instead of retaining a stale
        // element query tied to the pre-focus control type.
        let focusedComposer = messageComposer(in: app)
        XCTAssertTrue(focusedComposer.waitForExistence(timeout: 2))
        focusedComposer.typeText("Keep the response live")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))

        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isEnabled, "The compact send action must enable for the first draft in an existing chat.")
        send.tap()

        XCTAssertTrue(
            app.staticTexts["You: Keep the response live"].waitForExistence(timeout: 3),
            "The compact composer must send the first draft in an existing chat."
        )
        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 1),
            "Sending must resign the composer immediately so the live response has the full canvas."
        )

        let nextComposer = messageComposer(in: app)
        XCTAssertTrue(nextComposer.waitForExistence(timeout: 3))
        nextComposer.tap()
        nextComposer.typeText("Send another compact message")
        let nextSend = app.buttons["chat.send"]
        XCTAssertTrue(nextSend.waitForExistence(timeout: 2))
        XCTAssertTrue(nextSend.isEnabled)
        nextSend.tap()
        XCTAssertTrue(
            app.staticTexts["You: Send another compact message"].waitForExistence(timeout: 3),
            "Compact sending must continue to work after the first successful message."
        )
    }

    @MainActor
    func testExpandedComposerStillSendsItsFirstDraft() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        let draft = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nExpanded first send"
        composer.typeText(draft)

        let expand = app.buttons["chat.composer.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        expand.tap()
        let expanded = app.textViews["Expanded message"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 3))
        XCTAssertEqual(expanded.value as? String, draft)

        let panel = app.otherElements["chat.composer.expanded"]
        let send = panel.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(
            app.staticTexts["You: \(draft)"].waitForExistence(timeout: 3),
            "Expanded input must keep sending the first draft after compact hit routing is repaired."
        )
    }

    @MainActor
    func testSessionControlChipShowsQuickChoicesAndSearchableAllModelsDrawer() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-disable-demo-delays",
            "-start-chat",
            "-preview-ui-v3",
            "-loopdy.appearance.interface-version",
            "v3",
        ]
        app.launch()

        let controls = app.buttons["chat.session-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 3))
        XCTAssertTrue((controls.value as? String)?.contains("GPT-5.6") == true)
        controls.tap()

        let seeAll = app.buttons["chat.models.see-all"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 3))
        let recentModels = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.quick-model.")
        )
        let fixtureCurrent = app.buttons["chat.quick-model.openai:gpt-5.6"]
        XCTAssertTrue(fixtureCurrent.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(recentModels.count, 0)
        XCTAssertEqual(
            recentModels.allElementsBoundByIndex.filter { $0.isSelected }.count,
            1,
            "The current recent model must expose its selected state to assistive technology."
        )
        XCTAssertTrue(fixtureCurrent.isSelected)
        let fixtureAlternative = app.buttons["chat.quick-model.nous:Hermes-4-405B"]
        XCTAssertTrue(fixtureAlternative.waitForExistence(timeout: 3))
        fixtureAlternative.tap()
        let selectedAlternative = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in fixtureAlternative.isSelected },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedAlternative], timeout: 3), .completed)
        XCTAssertEqual(
            recentModels.allElementsBoundByIndex.filter { $0.isSelected }.count,
            1,
            "Choosing a recent model must leave exactly one selected model."
        )
        XCTAssertTrue(fixtureAlternative.isSelected)
        let reasoning = app.descendants(matching: .any)["chat.reasoning-slider"].firstMatch
        XCTAssertTrue(
            reasoning.waitForExistence(timeout: 3),
            "Choosing a recent model must keep its reasoning choices available."
        )
        XCTAssertEqual(reasoning.value as? String, "Auto")
        XCTAssertTrue(seeAll.waitForExistence(timeout: 3))

        seeAll.tap()

        let search = app.searchFields["Search providers and models"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("gpt-5.6")
        XCTAssertTrue(app.buttons["model-picker.openai.gpt-5.6"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testPhotoAttachmentDismissesDrawerAndReturnsComposerFocus() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-chat"]
        app.launch()

        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 3))
        attachment.tap()
        let photoAction = app.buttons["chat.action.photo"]
        XCTAssertTrue(photoAction.waitForExistence(timeout: 3))
        photoAction.tap()

        let onboardingClose = app.buttons["Close"]
        if onboardingClose.waitForExistence(timeout: 1) {
            onboardingClose.tap()
        }

        let firstPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 5))
        firstPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["chat.draft-attachments"].waitForExistence(timeout: 5),
            "The selected photo must return to the draft as a visible attachment."
        )
        XCTAssertTrue(
            photoAction.waitForNonExistence(timeout: 3),
            "A successful photo import must dismiss the bottom action drawer."
        )
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3),
            "A successful photo import must return focus to the message field."
        )
    }

    @MainActor
    func testChatPlusOpensBighelpActionSheetAndReusesAllModelsDrawer() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["root.new-chat"].tap()
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 3))
        attachment.tap()

        for identifier in [
            "chat.action.camera",
            "chat.action.photo",
            "chat.action.file",
            "chat.action.voice",
            "chat.action.start-session",
            "chat.action.choose-agent",
            "chat.action.skills-tools",
            "chat.action.change-model",
            "chat.action.workspace",
        ] {
            XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 2), identifier)
        }
        XCTAssertFalse(
            app.buttons["chat.action.reference"].exists,
            "Reference was intentionally removed from the attachment drawer."
        )

        app.buttons["chat.action.change-model"].tap()
        XCTAssertTrue(
            app.searchFields["Search providers and models"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testChatActionDrawerLoadsSkillsAndWorkspacesWithoutLeavingTheChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()

        app.buttons["chat.action.skills-tools"].tap()
        XCTAssertTrue(
            app.searchFields["Search skills and plugins"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["MCP servers"].exists)
        XCTAssertTrue(messageComposer(in: app).exists)

        app.buttons["Back to actions"].tap()
        app.buttons["chat.action.workspace"].tap()
        XCTAssertTrue(app.otherElements["hermes-workspaces.content"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["hermes-workspaces.create"].exists)
        XCTAssertTrue(app.buttons["hermes-workspace.loopdy"].exists)
        XCTAssertTrue(messageComposer(in: app).exists)
    }

    @MainActor
    func testProjectChangesRailShowsFileAndDiffCountsAndPanelNamesTheSelectedWorkspace() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-enable-project-changes"]
        app.launch()

        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 3))

        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let homeWorkspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(homeWorkspace.waitForExistence(timeout: 3))
        homeWorkspace.tap()

        dismissActionsAfterWorkspaceSelection(in: app)
        let changes = chatMenuItem("chat.file-changes", in: app)
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        XCTAssertFalse(changes.label.contains("Home"))
        XCTAssertTrue(
            changes.label.contains("1 file"),
            "Project Changes accessibility label: \(changes.label)"
        )
        XCTAssertTrue(changes.label.contains("additions"))
        XCTAssertTrue(changes.label.contains("deletions"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "File changes menu item with affected file count"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: changes
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 3), .completed)
        changes.tap()

        XCTAssertTrue(app.staticTexts["Project Changes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Home"].exists)
        XCTAssertTrue(app.staticTexts["main"].exists)
    }

    @MainActor
    func testFittingStatusRailDeadSpacePassesVerticalDragToChatTimeline() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-enable-project-changes",
        ]
        app.launch()

        app.buttons["tab.sessions"].tap()
        let session = app.buttons["session.row.demo-tool-folder-anchor"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 3))
        let previous = app.buttons["chat.show-previous-messages"]
        XCTAssertTrue(previous.waitForExistence(timeout: 3))
        previous.tap()
        let firstMessage = app.otherElements["chat.message.demo-tool-folder-anchor-earlier-1"]
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let homeWorkspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(homeWorkspace.waitForExistence(timeout: 3))
        homeWorkspace.tap()

        dismissActionsAfterWorkspaceSelection(in: app)

        for _ in 0..<6 where !firstMessage.isHittable {
            timeline.swipeDown()
        }
        XCTAssertTrue(firstMessage.isHittable)
        let finalMessage = app.otherElements["chat.message.demo-tool-folder-anchor-final"]
        XCTAssertFalse(
            finalMessage.isHittable,
            "The settled fixture must begin with its final message outside the visible viewport."
        )

        let deadSpace = app.otherElements["chat.session-status-rail-dead-space"]
        XCTAssertTrue(deadSpace.waitForExistence(timeout: 3))
        deadSpace.swipeUp()

        let finalMessageVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: finalMessage
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [finalMessageVisible], timeout: 3),
            .completed,
            "A vertical drag beginning in empty fitting-rail space must scroll the chat timeline. "
                + "app=\(app.frame), timeline=\(timeline.frame), deadSpace=\(deadSpace.frame)"
        )
    }

    @MainActor
    func testOverflowingStatusRailRevealsOffscreenCardsWithHorizontalSwipe() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-disable-demo-delays",
            "-enable-project-changes",
            "-use-overflow-status-rail-fixture",
            "-test-v3-session-status",
            "-start-chat",
            "-preview-ui-v3",
            "-loopdy.appearance.interface-version",
            "v3",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXL",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let homeWorkspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(homeWorkspace.waitForExistence(timeout: 3))
        homeWorkspace.tap()
        dismissActionsAfterWorkspaceSelection(in: app)

        let rail = app.descendants(matching: .any)["chat.session-status-rail"].firstMatch
        let goal = app.buttons["chat.session-status.goal"]
        let subagents = app.buttons["chat.session-status.subagents"]
        let tasks = app.buttons["chat.session-status.tasks"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        for control in [goal, subagents, tasks] {
            XCTAssertTrue(control.waitForExistence(timeout: 3))
        }
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismissRegion.exists {
            dismissRegion.tap()
        }

        for control in [goal, subagents, tasks] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.minX, rail.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, rail.frame.maxX)
        }
        XCTAssertLessThan(
            goal.frame.midY,
            tasks.frame.midY,
            "At accessibility sizes the overflowing rail must reflow vertically instead of hiding trailing cards."
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Accessibility status rail with all cards"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testProjectChangesMarkdownPreviewAndPanelExpansionOnIPad() throws {
        let app = makeApp()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = [
            "-use-demo-fixtures",
            "-enable-project-changes",
            "-use-project-changes-markdown-fixture",
            "-preview-ui-v3",
            "-disable-demo-delays",
        ]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        XCTAssertEqual(
            XCUIDevice.shared.orientation,
            .landscapeLeft,
            "Project Changes acceptance must run in iPad landscape."
        )

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()
        XCTAssertTrue(app.buttons["chat.attachment"].waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()
        let homeWorkspace = app.buttons["hermes-workspace.home"]
        XCTAssertTrue(homeWorkspace.waitForExistence(timeout: 3))
        homeWorkspace.tap()

        dismissActionsAfterWorkspaceSelection(in: app)
        let changes = chatMenuItem("chat.file-changes", in: app)
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        changes.tap()

        let panel = app.otherElements["project-changes.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let splitWidth = panel.frame.width
        XCTAssertLessThan(splitWidth, app.frame.width * 0.75)
        let markdownFile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "README.md,")
        ).firstMatch
        XCTAssertTrue(markdownFile.waitForExistence(timeout: 3))
        markdownFile.tap()

        let preview = app.buttons["Preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["+# Fixture Markdown Preview"].exists)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Fixture Markdown Preview"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["+# Fixture Markdown Preview"].exists)

        let previewAttachment = XCTAttachment(screenshot: app.screenshot())
        previewAttachment.name = "Project Changes rendered Markdown preview at split width"
        previewAttachment.lifetime = .keepAlways
        add(previewAttachment)

        let textFile = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "notes.txt,")
        ).firstMatch
        XCTAssertTrue(textFile.waitForExistence(timeout: 3))
        textFile.tap()
        XCTAssertTrue(app.staticTexts["+Plain text diff opens in Diff mode"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Preview"].waitForExistence(timeout: 3))
        app.buttons["Preview"].tap()
        let literalText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "**This stays literal in TXT.**")).firstMatch
        XCTAssertTrue(literalText.waitForExistence(timeout: 3))
        let textPreviewAttachment = XCTAttachment(screenshot: app.screenshot())
        textPreviewAttachment.name = "Project Changes plain text preview preserves literal Markdown"
        textPreviewAttachment.lifetime = .keepAlways
        add(textPreviewAttachment)

        let changesScroll = panel.scrollViews.firstMatch
        for _ in 0..<6 where !markdownFile.exists || !markdownFile.isHittable {
            changesScroll.swipeUp()
        }
        XCTAssertTrue(markdownFile.exists)
        markdownFile.tap()
        XCTAssertTrue(app.buttons["Preview"].waitForExistence(timeout: 3))
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.staticTexts["Fixture Markdown Preview"].waitForExistence(timeout: 3))

        let resizeHandle = app.otherElements["project-changes.resize-handle"]
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 3))
        let expandPanel = app.buttons["Expand project changes"]
        XCTAssertTrue(expandPanel.waitForExistence(timeout: 3))
        expandPanel.tap()

        let chatCanvas = app.descendants(matching: .any)["chat.canvas"].firstMatch
        XCTAssertTrue(chatCanvas.exists)
        let expectedExpandedWidth = chatCanvas.frame.width * 0.9
        let expansionDeadline = Date().addingTimeInterval(3)
        while panel.frame.width < expectedExpandedWidth, Date() < expansionDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertGreaterThan(
            panel.frame.width,
            splitWidth + 100,
            "Dragging left must materially expand the Project Changes panel."
        )
        XCTAssertGreaterThanOrEqual(
            panel.frame.width,
            expectedExpandedWidth,
            "The expanded Project Changes panel must occupy the iPad canvas."
        )

        let previewHeading = app.staticTexts["Fixture Markdown Preview"]
        XCTAssertTrue(previewHeading.isHittable)
        let initialHeadingY = previewHeading.frame.minY
        let dragStart = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.8))
        let dragEnd = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.2))
        dragStart.press(forDuration: 0.1, thenDragTo: dragEnd)
        let scrollDeadline = Date().addingTimeInterval(3)
        while previewHeading.frame.minY > initialHeadingY - 100, Date() < scrollDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertLessThan(
            previewHeading.frame.minY,
            initialHeadingY - 100,
            "Vertical drags inside the expanded panel must scroll its Markdown content."
        )

        let fullScreenAttachment = XCTAttachment(screenshot: app.screenshot())
        fullScreenAttachment.name = "Project Changes rendered Markdown preview expanded full screen"
        fullScreenAttachment.lifetime = .keepAlways
        add(fullScreenAttachment)
    }

    @MainActor
    func testFullModelPickerKeepsTheGradientControlVisibleAfterSelection() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()
        app.buttons["root.new-chat"].tap()
        let controls = app.buttons["chat.session-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        let all = app.buttons["chat.models.see-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let search = app.searchFields["Search providers and models"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("gpt-5.6")
        let model = app.buttons["model-picker.openai.gpt-5.6"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        model.tap()
        let slider = app.descendants(matching: .any).matching(identifier: "model-picker.reasoning-slider").firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertTrue(slider.isHittable)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65)).press(forDuration: 0.1,
            thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)))
        XCTAssertTrue(slider.isHittable)
        XCTAssertTrue(app.buttons["model-picker.apply"].isHittable)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "post111-full-model-reasoning"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testReasoningChoicesStayVisibleWhenModelSelectionChangesPages() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }

        let newChat = app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 3))
        newChat.tap()

        let controls = app.buttons["chat.session-controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()

        let quickModel = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.quick-model.")
        ).firstMatch
        XCTAssertTrue(quickModel.waitForExistence(timeout: 5))
        XCTAssertTrue(quickModel.isHittable)
        quickModel.tap()

        let reasoningChoice = app.descendants(matching: .any).matching(identifier: "chat.reasoning-slider").firstMatch
        XCTAssertTrue(reasoningChoice.waitForExistence(timeout: 5))
        XCTAssertTrue(
            reasoningChoice.isHittable,
            "Reasoning choices must reset to the visible top after selecting a model."
        )

        let sliderStart = reasoningChoice.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        sliderStart.press(forDuration: 0.05, thenDragTo: reasoningChoice.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.65)))
        XCTAssertTrue(reasoningChoice.isHittable, "Changing reasoning must not navigate away from its controls.")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "post111-reasoning-portrait"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(reasoningChoice.waitForExistence(timeout: 3))
        XCTAssertTrue(
            reasoningChoice.isHittable,
            "Reasoning choices must remain visible in compact-height landscape."
        )
    }

    @MainActor
    func testSavedSessionLoadsOlderHistoryOnlyWhenRequested() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["tab.sessions"].tap()
        let session = app.buttons["session.row.demo-tool-folder-anchor"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertEqual(timeline.value as? String, "2 conversation entries")

        let previous = app.buttons["chat.show-previous-messages"]
        for _ in 0..<6 where !previous.isHittable {
            timeline.swipeDown()
        }
        XCTAssertTrue(previous.isHittable)
        previous.tap()

        let loadedEntries = NSPredicate(
            format: "value == %@",
            "22 conversation entries"
        )
        expectation(for: loadedEntries, evaluatedWith: timeline)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(previous.exists)
    }

    @MainActor
    func testExpandingToolFolderAllowsReviewAndReturnsToTheFinalAnswer() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["tab.sessions"].tap()
        let session = app.buttons["session.row.demo-tool-folder-anchor"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()

        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let finalAnswer = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Anchor sentinel stays visible.")
        ).firstMatch
        XCTAssertTrue(finalAnswer.waitForExistence(timeout: 5))
        XCTAssertTrue(finalAnswer.isHittable, "The restored chat must begin at its final answer.")

        let completedTurn = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.completed-turn:")
        ).firstMatch
        XCTAssertTrue(completedTurn.waitForExistence(timeout: 5))
        completedTurn.tap()

        let workTrail = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")
        ).firstMatch
        XCTAssertTrue(workTrail.waitForExistence(timeout: 5))
        workTrail.tap()

        let firstTool = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.activity.")
        ).firstMatch
        XCTAssertTrue(firstTool.waitForExistence(timeout: 5))
        XCTAssertTrue(firstTool.isHittable, "Expanding work is a request to read its tools.")
        let latest = app.buttons.matching(
            NSPredicate(format: "label == %@", "Return to latest messages")
        ).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        latest.tap()
        let finalAnswerAfterExpansion = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Anchor sentinel stays visible.")
        ).firstMatch
        XCTAssertTrue(
            finalAnswerAfterExpansion.waitForExistence(timeout: 5)
                && finalAnswerAfterExpansion.isHittable,
            "Returning from expanded work must restore the final answer above the composer."
        )
        XCTAssertLessThanOrEqual(finalAnswerAfterExpansion.frame.maxY, timeline.frame.maxY)
    }

    @MainActor
    func testReturnToLatestKeepsTheLongTranscriptVisibleAfterRepeatedReturns() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-long-transcript", "-preview-ui-v3"]
        app.launch()
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let tail = app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", "Long transcript settled sentinel 1000")
        ).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
        // The timeline's container identifier is inherited by its overlay button.
        let latest = app.buttons.matching(
            NSPredicate(format: "label == %@", "Return to latest messages")
        ).firstMatch
        for _ in 0..<3 {
            timeline.swipeDown()
            XCTAssertTrue(latest.waitForExistence(timeout: 3))
            latest.tap()
            XCTAssertTrue(tail.waitForExistence(timeout: 5))
            XCTAssertTrue(tail.isHittable)
            XCTAssertTrue(tail.frame.intersects(timeline.frame))
            XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "long-transcript-return-visible"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testLongFixtureTranscriptUpdatesItsLiveTailWithoutLosingSettledHistory() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-disable-demo-delays",
            "-start-long-transcript",
            "-preview-ui-v3",
        ]
        app.launch()

        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertEqual(timeline.value as? String, "1000 conversation entries")
        let restoredTail = app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", "Long transcript settled sentinel 1000")
        ).firstMatch
        XCTAssertTrue(
            restoredTail.waitForExistence(timeout: 5) && restoredTail.isHittable,
            "A restored 1,000-entry transcript must open at its live tail."
        )

        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.tap()
        composer.typeText("Update the long transcript tail")
        app.buttons["chat.send"].tap()

        let updatedTail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Update the long transcript tail")
        ).firstMatch
        XCTAssertTrue(
            updatedTail.waitForExistence(timeout: 5) && updatedTail.isHittable,
            "Appending to a large transcript must keep the new live tail visible."
        )
        XCTAssertEqual(timeline.value as? String, "1002 conversation entries")
    }

    @MainActor
    func testWorkspaceFooterOpensHermesWorkspacePicker() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["home.drawer.open"].tap()
        let workspaces = app.buttons["menu.folder"]
        XCTAssertTrue(workspaces.waitForExistence(timeout: 3))
        workspaces.tap()

        XCTAssertTrue(app.otherElements["hermes-workspaces.screen"].waitForExistence(timeout: 3))
        let create = app.buttons["hermes-workspaces.create"]
        XCTAssertTrue(create.exists)
        XCTAssertTrue(create.isHittable)
        XCTAssertTrue(app.buttons["hermes-workspace.loopdy"].exists)
    }

    @MainActor
    func testScheduledTaskWeekdaysToggleIndependentlyAndOutputChannelIsExposed() throws {
        try verifyScheduledTaskEditor()
    }

    @MainActor
    func testV3ScheduledTaskListDetailAndEditor() throws {
        try verifyScheduledTaskEditor(v3: true)
    }

    @MainActor
    private func verifyScheduledTaskEditor(v3: Bool = false) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        if v3 {
            app.launchArguments += ["-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"]
        }
        app.launch()

        app.buttons["home.drawer.open"].tap()
        let scheduledTasks = app.buttons["menu.scheduled-tasks"]
        XCTAssertTrue(scheduledTasks.waitForExistence(timeout: 3))
        scheduledTasks.tap()

        let create = app.buttons["scheduled-tasks.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        if v3 {
            saveV2Evidence(app, name: "v3-scheduled-tasks")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-task.row.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "scheduled-task.detail.")).firstMatch.waitForExistence(timeout: 3))
            saveV2Evidence(app, name: "v3-scheduled-task-detail")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(create.waitForExistence(timeout: 3))
        }
        create.tap()

        let monday = app.buttons["scheduled-task.editor.weekday.monday"]
        let tuesday = app.buttons["scheduled-task.editor.weekday.tuesday"]
        XCTAssertTrue(monday.waitForExistence(timeout: 3))
        XCTAssertTrue(tuesday.exists)
        XCTAssertEqual(monday.value as? String, "Selected")
        XCTAssertEqual(tuesday.value as? String, "Selected")

        monday.tap()

        XCTAssertEqual(monday.value as? String, "Not selected")
        XCTAssertEqual(tuesday.value as? String, "Selected")
        if v3 {
            saveV2Evidence(app, name: "v3-scheduled-task-editor")
            for _ in 0..<3 where !app.buttons["scheduled-task.editor.delivery"].exists {
                app.swipeUp()
            }
        }
        XCTAssertTrue(app.buttons["scheduled-task.editor.delivery"].exists)
        if v3 { saveV2Evidence(app, name: "v3-scheduled-task-delivery") }
    }

    @MainActor
    func testChatActionDrawerUsesSharedWorkspaceManager() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 3))
        app.buttons["chat.attachment"].tap()
        app.buttons["chat.action.workspace"].tap()

        XCTAssertTrue(app.otherElements["hermes-workspaces.content"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["hermes-workspaces.create"].exists)
        XCTAssertTrue(app.buttons["hermes-workspace.loopdy"].exists)
        XCTAssertTrue(messageComposer(in: app).exists)
    }

    @MainActor
    func testSharedWorkspaceManagerCreatesFromRemoteFolderSuggestionAndConfirmsArchive() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["home.drawer.open"].tap()
        XCTAssertTrue(app.buttons["menu.folder"].waitForExistence(timeout: 3))
        app.buttons["menu.folder"].tap()

        let create = app.buttons["hermes-workspaces.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()

        let name = app.textFields["hermes-workspaces.create.name"]
        let path = app.textFields["hermes-workspaces.create.path"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertTrue(path.exists)
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        name.typeText("bighelp Native")
        path.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        path.typeText("/srv/workspaces/loo")

        let suggestion = app.buttons["hermes-workspaces.folder-suggestion.0"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        suggestion.tap()
        XCTAssertEqual(path.value as? String, "/srv/workspaces/loopdy-native")

        app.buttons["hermes-workspaces.create.submit"].tap()
        let created = app.buttons["hermes-workspace.fixture-bighelp-native"]
        XCTAssertTrue(created.waitForExistence(timeout: 3))

        app.buttons["hermes-workspace.archive.fixture-bighelp-native"].tap()
        let confirmation = app.buttons["Archive Workspace"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        XCTAssertFalse(created.waitForExistence(timeout: 1))
    }

    @MainActor
    func testNewWorkspaceBrowsesHomeFoldersAndAcceptsTildePaths() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        app.buttons["home.drawer.open"].tap()
        XCTAssertTrue(app.buttons["menu.folder"].waitForExistence(timeout: 3))
        app.buttons["menu.folder"].tap()
        let create = app.buttons["hermes-workspaces.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()

        // Nothing typed yet: home's folders, hidden ones left out.
        let projects = app.buttons.matching(identifier: "hermes-workspaces.folder-suggestion.2").firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 3))
        XCTAssertEqual(projects.label, "Projects")
        XCTAssertFalse(app.buttons[".config"].exists)
        saveWorkspaceBrowse("workspace-1-home", app)

        // Tapping opens the folder, fills the path, and names the workspace.
        projects.tap()
        let path = app.textFields["hermes-workspaces.create.path"]
        XCTAssertEqual(path.value as? String, "~/Projects")
        XCTAssertEqual(app.textFields["hermes-workspaces.create.name"].value as? String, "Projects")
        let native = app.buttons["hermes-workspaces.folder-suggestion.0"]
        XCTAssertTrue(native.waitForExistence(timeout: 3))
        XCTAssertEqual(native.label, "bighelp-native")
        saveWorkspaceBrowse("workspace-2-projects", app)

        app.buttons["hermes-workspaces.folder-up"].tap()
        XCTAssertEqual(path.value as? String, "~")

        // Typing narrows the list to matching folders.
        path.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        path.typeText("/Projects/gar")
        let garden = app.buttons["hermes-workspaces.folder-suggestion.0"]
        XCTAssertTrue(garden.waitForExistence(timeout: 3))
        XCTAssertEqual(garden.label, "garden-planner")
        garden.tap()
        XCTAssertEqual(path.value as? String, "~/Projects/garden-planner")
        XCTAssertTrue(app.staticTexts["Full path: /Users/demo/Projects/garden-planner"].waitForExistence(timeout: 3))
        saveWorkspaceBrowse("workspace-3-typed", app)

        app.buttons["hermes-workspaces.create.submit"].tap()
        let created = app.buttons["hermes-workspace.fixture-garden-planner"]
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        XCTAssertTrue(created.label.contains("/Users/demo/Projects/garden-planner"), created.label)
    }

    @MainActor
    private func saveWorkspaceBrowse(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_WORKSPACE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testUnavailableCameraActionIsDisabledInTheChatActionSheet() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let newChat = app.navigationBars["Chats"].buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.waitForExistence(timeout: 3))
        attachment.tap()

        let camera = app.buttons["chat.action.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 2))
        XCTAssertFalse(
            camera.isEnabled,
            "The camera action must not be actionable when the current device has no camera."
        )
    }

    @MainActor
    func testAgentSettingsExposeSeparateRuntimeDefaultsThroughTheSharedModelDrawer() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        let navigation = app.buttons["home.drawer.open"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        navigation.tap()
        let agents = app.buttons["menu.agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3))
        agents.tap()
        let actions = app.buttons["agent.finance"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        app.buttons["agent.finance.more"].tap()
        let actionList = app.descendants(matching: .any)["agent.actions.list"].firstMatch
        XCTAssertTrue(actionList.waitForExistence(timeout: 3))
        let edit = app.buttons["agent.finance.edit"]
        for _ in 0..<5 where !edit.isHittable { actionList.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        edit.tap()

        let editor = app.descendants(matching: .any)["agent.editor.edit"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        func reveal(_ identifier: String) -> XCUIElement {
            let element = app.buttons[identifier]
            for _ in 0..<8 where !element.isHittable {
                editor.swipeUp()
            }
            XCTAssertTrue(element.isHittable, "Visible editable control: \(identifier)")
            return element
        }

        let mainModel = reveal("agent.runtime.mainChats.model")
        XCTAssertTrue(mainModel.exists, "agent.runtime.mainChats.model")
        mainModel.tap()
        XCTAssertTrue(
            app.searchFields["Search providers and models"].waitForExistence(timeout: 3),
            "Agent defaults must reuse the full searchable model drawer."
        )
        let nousProvider = app.buttons["model-picker.provider.nous"]
        XCTAssertTrue(nousProvider.exists)
        XCTAssertEqual(nousProvider.value as? String, "Expanded")
        XCTAssertTrue(app.buttons["model-picker.nous.Hermes-4-405B"].exists,
                      "The selected provider is expanded by the current picker design.")
        nousProvider.tap()
        XCTAssertEqual(nousProvider.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["model-picker.nous.Hermes-4-405B"].exists)
        nousProvider.tap()
        XCTAssertEqual(nousProvider.value as? String, "Expanded")
        XCTAssertTrue(
            app.buttons["model-picker.nous.Hermes-4-405B"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Hermes 4 405B"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Friendly model picker"
        capture.lifetime = .keepAlways
        add(capture)
        // Reasoning is chosen in the same picker, as in chat, then applied to the agent.
        let reasoningPicker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reasoning,")).firstMatch
        XCTAssertTrue(reasoningPicker.waitForExistence(timeout: 3))
        reasoningPicker.tap()
        let high = app.buttons["High"].firstMatch
        XCTAssertTrue(high.waitForExistence(timeout: 3))
        high.tap()
        let apply = app.buttons["model-picker.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        XCTAssertEqual(apply.label, "Use for this agent")
        apply.tap()
        XCTAssertTrue(apply.waitForNonExistence(timeout: 3))
        let updated = reveal("agent.runtime.mainChats.model")
        XCTAssertTrue((updated.value as? String)?.contains("reasoning High") == true,
                      "The agent's model row shows the chosen reasoning level.")

        let advanced = app.buttons["agent.editor.advanced"]
        for _ in 0..<4 where !advanced.isHittable { editor.swipeUp() }
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced"].waitForExistence(timeout: 3))
        for identifier in [
            "agent.runtime.subagents.model", "agent.runtime.scheduledTasks.model"
        ] {
            XCTAssertTrue(app.buttons[identifier].exists, identifier)
        }
        app.navigationBars["Advanced"].buttons.firstMatch.tap()
        app.buttons["agent.editor.cancel"].tap()
        let discard = app.alerts["Discard agent changes?"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3))
        discard.buttons["Discard changes"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testVoicePermissionsReturnToLiveVoiceScreenWithoutTerminatingApp() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]

        app.launch()

        let shellNewChat = app.buttons["root.new-chat"]
        XCTAssertTrue(shellNewChat.waitForExistence(timeout: 3))
        shellNewChat.tap()

        let voiceButton = app.buttons["Open voice chat"]
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 3))
        voiceButton.tap()

        XCTAssertTrue(app.staticTexts["Voice chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Listening"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["End voice chat"].isHittable)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testWalkieTalkieReleaseCannotLeaveCaptureLatched() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-loopdy.voice.mode", "walkieTalkie"]
        app.launch()
        app.buttons["root.new-chat"].tap()
        app.buttons["chat.attachment"].tap()
        let voice = app.buttons["chat.action.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 3))
        voice.tap()
        let speak = app.descendants(matching: .any).matching(identifier: "voice.walkie-talkie.speak").firstMatch
        XCTAssertTrue(speak.waitForExistence(timeout: 5))
        XCTAssertTrue(speak.isHittable)
        speak.press(forDuration: 0.8)
        XCTAssertEqual(speak.value as? String, "Ready", "Release must stop capture without toggling it back on.")
        speak.tap()
        XCTAssertEqual(speak.value as? String, "Ready", "A quick touch must not latch the microphone.")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "post111-walkie-released"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    func testChatActionDrawerDismissesBeforePresentingVoice() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]

        app.launch()
        app.buttons["root.new-chat"].tap()
        app.buttons["chat.attachment"].tap()

        let drawerVoice = app.buttons["chat.action.voice"]
        XCTAssertTrue(drawerVoice.waitForExistence(timeout: 3))
        drawerVoice.tap()

        XCTAssertTrue(app.staticTexts["Voice chat"].waitForExistence(timeout: 5))
        let endVoice = app.buttons["End voice chat"]
        XCTAssertTrue(endVoice.isHittable)
        XCTAssertFalse(app.buttons["chat.action.voice"].exists)
        XCTAssertEqual(app.state, .runningForeground)

        endVoice.tap()

        XCTAssertTrue(messageComposer(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons["chat.action.voice"].waitForExistence(timeout: 1),
            "Ending voice must return directly to chat instead of resurrecting the action drawer."
        )
    }

    @MainActor
    func testLegacyInboxLaunchRedirectsToHomeSignals() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-start-inbox"]
        app.launch()

        XCTAssertTrue(app.scrollViews["dashboard.screen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.inbox"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.needs-you"].exists)
        XCTAssertFalse(app.otherElements["inbox.screen"].exists)
        XCTAssertFalse(app.buttons["tab.inbox"].exists)
    }

    @MainActor
    func testHostDiagnosticsExplainsGatewayRestartAndUnsupportedStates() throws {
        for (scenario, title) in [
            ("gateway-outdated", "Hermes compatibility needs attention"),
            ("restart", "Host restart required"),
            ("unsupported", "Host diagnostics not supported")
        ] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-host-diagnostics-fixture", scenario]
            app.launch()
            openSettings(in: app)
            let connectivity = settingsRow("settings.menu.connectivityAndNotifications", in: app)
            for _ in 0..<6 where !connectivity.isHittable { app.swipeUp() }
            XCTAssertTrue(connectivity.isHittable)
            connectivity.tap()
            let finding = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "settings.host-runtime-status", title)
            ).firstMatch
            for _ in 0..<5 where !finding.exists { app.swipeUp() }
            XCTAssertTrue(finding.waitForExistence(timeout: 5), scenario)
            let check = app.buttons["settings.check-host-runtime"]
            for _ in 0..<5 where !check.isHittable { app.swipeUp() }
            XCTAssertTrue(check.isHittable, scenario)
            let capture = XCTAttachment(screenshot: app.screenshot())
            capture.name = "Host diagnostics " + scenario
            capture.lifetime = .keepAlways
            add(capture)
            check.tap()
            XCTAssertFalse(app.alerts["Update bighelp Plugin?"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testSettingsExposesSeparatePluginAndModelNameUpdates() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-plugin-update-fixture"]
        app.launch()
        openSettings(in: app)
        let connectivity = settingsRow("settings.menu.connectivityAndNotifications", in: app)
        for _ in 0..<5 where !connectivity.isHittable { app.swipeUp() }
        XCTAssertTrue(connectivity.waitForExistence(timeout: 3))
        connectivity.tap()
        let plugin = app.buttons["settings.update-plugin"]
        for _ in 0..<4 where !plugin.isHittable { app.swipeUp() }
        XCTAssertTrue(plugin.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings.update-model-names"].exists)
        plugin.tap()
        XCTAssertTrue(app.alerts["Update bighelp Plugin?"].waitForExistence(timeout: 2))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Complete"].exists)
        plugin.tap()
        app.alerts.buttons["Update and Restart"].tap()
        XCTAssertTrue(app.staticTexts["Complete"].waitForExistence(timeout: 12))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Plugin update settings"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testProfileUsesFocusedSettingsMenusAndExposesChatVisibilityDefaults() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        openSettings(in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.screen"].waitForExistence(timeout: 3)
        )

        for identifier in [
            "settings.menu.workspace",
            "settings.menu.agentsAndPersonalities",
            "settings.menu.chat",
        ] {
            XCTAssertTrue(settingsRow(identifier, in: app).waitForExistence(timeout: 2), identifier)
        }

        let chatSettings = settingsRow("settings.menu.chat", in: app)
        let primaryNavigation = app.otherElements["primary-navigation"]
        for _ in 0..<4 where chatSettings.frame.maxY > primaryNavigation.frame.minY {
            app.swipeUp()
        }
        XCTAssertLessThanOrEqual(
            chatSettings.frame.maxY,
            primaryNavigation.frame.minY,
            "Chat & Voice must scroll fully above the attached navigation bar."
        )
        XCTAssertTrue(chatSettings.isHittable, "Chat & Voice must remain reachable in the settings menu.")
        chatSettings.tap()
        XCTAssertTrue(app.navigationBars["Chat & Voice"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["settings.chat.show-reasoning"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["settings.chat.show-tool-calls"].exists)
    }

    @MainActor
    func testHostsSettingsClearLocalCacheAndRefreshFreshData() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures"]
        app.launch()

        openSettings(in: app)

        // Nerd Mode (on in UI tests) keeps Clear Local Cache on the Hosts page.
        let hosts = settingsRow("settings.menu.connectivityAndNotifications", in: app)
        XCTAssertTrue(hosts.waitForExistence(timeout: 3))
        hosts.tap()

        let clearCache = app.buttons["settings.account.clear-local-cache"]
        for _ in 0..<6 where !clearCache.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(clearCache.waitForExistence(timeout: 3))
        XCTAssertTrue(clearCache.isEnabled)
        clearCache.tap()

        XCTAssertTrue(app.alerts["Clear local cache?"].waitForExistence(timeout: 3))
        let confirm = app.buttons["Clear Cache and Refresh"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let status = app.staticTexts["settings.account.clear-local-cache-status"]
        for _ in 0..<6 where !status.exists {
            app.swipeUp()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "Local cache cleared. Fresh data is ready.")
        XCTAssertTrue(clearCache.isEnabled)
    }

    @MainActor
    func testMidSessionHoldPresentsOptionsWhileTouchIsActiveAndConsumesRelease() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-start-chat-mid-session",
            "-observe-send-hold",
        ]
        app.launch()

        let send = app.descendants(matching: .any)["chat.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isHittable)
        XCTAssertTrue(send.frame.width.isFinite && send.frame.width > 0)
        XCTAssertTrue(send.frame.height.isFinite && send.frame.height > 0)
        let composer = messageComposer(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        XCTAssertEqual(composer.value as? String, "Review the latest finance update")

        send.press(forDuration: 3.4)

        XCTAssertTrue(app.otherElements["chat.send.mid-session.options"].waitForExistence(timeout: 3))
        let facts = send.value as? String ?? ""
        XCTAssertTrue(facts.contains("thresholdReached=true"), facts)
        XCTAssertTrue(facts.contains("optionsAppeared=true"), facts)
        XCTAssertTrue(facts.contains("touchActiveWhenOptionsAppeared=true"), facts)
        XCTAssertFalse(app.staticTexts["You: Review the latest finance update"].exists)
        app.otherElements["chat.send.mid-session.options"].swipeDown()
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["You: Review the latest finance update"].waitForExistence(timeout: 3),
                      "Cancelling send alternatives must not disable later short taps.")
    }
}
