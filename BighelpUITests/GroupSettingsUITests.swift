import XCTest

/// Group Settings and the lines a group chat shows about who took a message (#860), on the demo
/// group chat Hermes runs itself (`-preview-group-settings`).
final class GroupSettingsUITests: BighelpUITestCase {
    @MainActor
    private func openGroup(appearance: String, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-group-settings",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        // The demo has many group chats: New chat's To field finds this one among them.
        chatNewChatButton(in: app).tap()
        let to = app.textFields["new-chat.to.field"].firstMatch
        XCTAssertTrue(to.waitForExistence(timeout: 10))
        to.tap()
        to.typeText("Garden party")
        let group = app.buttons["new-chat.group.hermes-room:group-settings-demo"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 8), "New chat lists the demo's group chat")
        group.tap()
        XCTAssertTrue(to.waitForNonExistence(timeout: 10), "The group chat takes New chat's place")
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        return app
    }

    /// Purpose wraps (a vertical text field), which XCUITest may list as a text view.
    @MainActor
    private func field(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// The chat says who took each message, the paused discussion goes on with Continue, and
    /// the header's name opens Group Settings, where a change saves and stays.
    @MainActor
    func testRoutingLinesContinueAndGroupSettings() {
        for appearance in ["light", "dark"] { checkRoutingAndSettings(appearance: appearance) }
    }

    @MainActor
    private func checkRoutingAndSettings(appearance: String) {
        let app = openGroup(appearance: appearance)
        XCTAssertTrue(app.staticTexts["Avery Park gave this to Jordan Lee"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Assigned to Avery Park and Jordan Lee"].exists)
        XCTAssertTrue(app.staticTexts["Lead: Avery Park"].exists, "The header names the lead")
        let continueButton = app.buttons["chat.group-paused.continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Paused after 10 messages."].exists)
        XCTAssertTrue(app.buttons["chat.group-paused.stop"].exists)
        keep(app, "group-routing-lines-\(appearance)")

        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Continued"].waitForExistence(timeout: 10))
        XCTAssertTrue(continueButton.waitForNonExistence(timeout: 5), "A continued pause has no buttons")
        let answer = app.textViews.matching(NSPredicate(
            format: "identifier == 'chat.message.inline-selection' AND label CONTAINS %@", "wildflowers and lanterns"
        )).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "The discussion goes on")

        app.descendants(matching: .any)["chat.people"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["group-settings"].firstMatch.waitForExistence(timeout: 5))
        let lead = app.buttons["group-settings.routing.lead"]
        XCTAssertTrue(lead.waitForExistence(timeout: 5))
        XCTAssertEqual(lead.value as? String, "Lead: Avery Park")
        XCTAssertTrue(app.buttons["group-settings.routing.everyone"].exists)
        XCTAssertTrue(app.buttons["group-settings.routing.auto"].exists, "The demo's runtime picks automatically")
        XCTAssertTrue(app.descendants(matching: .any)["group-settings.member.member-finance"].label.contains("lead"))
        keep(app, "group-settings-\(appearance)")

        app.buttons["group-settings.routing.auto"].tap()
        XCTAssertTrue(app.buttons["group-settings.routing.auto"].isSelected)
        let purpose = field("group-settings.purpose", in: app)
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        purpose.tap()
        purpose.typeText(" in May\n")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Lead: Avery Park"].waitForNonExistence(timeout: 5),
                      "Nobody leads once a quick check picks")
        let menuItem = chatMenuItem("chat.group-settings", in: app)
        XCTAssertTrue(menuItem.exists && menuItem.isHittable, "⋯ opens Group Settings too")
        menuItem.tap()
        let saved = field("group-settings.purpose", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertTrue((saved.value as? String)?.contains("in May") == true, "The purpose was saved")
        XCTAssertTrue(app.buttons["group-settings.routing.auto"].isSelected)
        app.terminate()
    }

    /// A room another computer runs refuses the save: the edit stays, with why and a way out.
    @MainActor
    func testARefusedSaveKeepsTheEditAndSaysWhy() {
        let app = openGroup(appearance: "light", extra: ["-preview-group-settings-refused"])
        app.descendants(matching: .any)["chat.people"].firstMatch.tap()
        let auto = app.buttons["group-settings.routing.auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 5))
        auto.tap()
        let problem = app.descendants(matching: .any)["group-settings.problem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertTrue(problem.label.contains("Another computer runs this group chat"))
        XCTAssertTrue(auto.isSelected, "The edit stays")
        keep(app, "group-settings-refused")
        app.buttons["group-settings.discard"].tap()
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["group-settings.routing.lead"].isSelected)
        app.terminate()
    }

    /// New Group Chat asks who answers and the purpose, and the group starts with them.
    @MainActor
    func testNewGroupChatStartsWithItsChoice() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-group-create",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        // Bots › + › New Group Chat.
        showBots(in: app)
        let add = app.buttons["simple-bots.new"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let create = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                      "simple-bots.new.group", "New Group Chat")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let everyone = app.buttons["bot-mode.create.routing.everyone"]
        XCTAssertTrue(everyone.waitForExistence(timeout: 5))
        XCTAssertTrue(everyone.isSelected, "Everyone answers unless the person picks otherwise")
        app.buttons["bot-mode.create.participant.finance"].tap()
        app.buttons["bot-mode.create.participant.home"].tap()
        let lead = app.buttons["bot-mode.create.routing.lead"]
        XCTAssertTrue(lead.waitForExistence(timeout: 5))
        lead.tap()
        let jordan = app.buttons["Jordan Lee"]
        XCTAssertTrue(jordan.waitForExistence(timeout: 5))
        jordan.tap()
        XCTAssertEqual(lead.value as? String, "Lead: Jordan Lee")
        let title = app.textFields["bot-mode.create.title"]
        title.tap()
        title.typeText("Supper club\n")
        let purpose = field("bot-mode.create.purpose", in: app)
        purpose.tap()
        purpose.typeText("Plan Friday supper\n")
        keep(app, "new-group-chat-routing")
        app.buttons["bot-mode.create.submit"].tap()

        XCTAssertTrue(app.staticTexts["Lead: Jordan Lee"].waitForExistence(timeout: 10), "The group starts with its lead")
        app.descendants(matching: .any)["chat.people"].firstMatch.tap()
        let saved = field("group-settings.purpose", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertEqual(saved.value as? String, "Plan Friday supper")
        app.terminate()
    }

    /// At the largest text sizes every row wraps and stays reachable.
    @MainActor
    func testGroupSettingsAtALargeTextSize() {
        let app = openGroup(appearance: "light",
                            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        keep(app, "group-routing-lines-large-text")
        // Folded at this size, This chat holds Group Settings without scrolling.
        let menuItem = chatMenuItem("chat.group-settings", in: app)
        XCTAssertTrue(menuItem.exists)
        XCTAssertTrue(menuItem.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(menuItem.frame), "Group Settings fits on screen")
        keep(app, "group-chat-menu-large-text")
        menuItem.tap()
        XCTAssertTrue(app.descendants(matching: .any)["group-settings"].firstMatch.waitForExistence(timeout: 5))
        keep(app, "group-settings-large-text-top")
        let notes = app.textViews["group-settings.notes"]
        for _ in 0..<8 where !(notes.exists && notes.isHittable) { app.swipeUp() }
        XCTAssertTrue(notes.isHittable, "Shared notes can be reached")
        XCTAssertTrue(app.descendants(matching: .any)["group-settings.notes-count"].firstMatch.exists)
        keep(app, "group-settings-large-text-notes")
        app.terminate()
    }
}
