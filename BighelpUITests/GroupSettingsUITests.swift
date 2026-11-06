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
        openAgents(in: app)
        let search = app.searchFields["Search agents and groups"].firstMatch
        XCTAssertTrue(revealSearchField(search, in: app))
        search.tap()
        search.typeText("Garden\n")
        let group = app.buttons["agents.group.group-settings-demo"]
        XCTAssertTrue(group.waitForExistence(timeout: 8))
        group.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
        let purpose = app.textFields["group-settings.purpose"]
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        purpose.tap()
        purpose.typeText(" in May\n")
        XCTAssertFalse(app.descendants(matching: .any)["group-settings.problem"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Lead: Avery Park"].exists, "Nobody leads once a quick check picks")
        app.buttons["chat.options"].tap()
        let menuItem = app.buttons["chat.group-settings"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "⋯ opens Group Settings too")
        menuItem.tap()
        let saved = app.textFields["group-settings.purpose"]
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

    /// At the largest text sizes every row wraps and stays reachable.
    @MainActor
    func testGroupSettingsAtALargeTextSize() {
        let app = openGroup(appearance: "light",
                            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        keep(app, "group-routing-lines-large-text")
        // Folded at this size, This chat holds Group Settings without scrolling.
        app.buttons["chat.options"].tap()
        let thisChat = app.buttons["chat.options.this-chat"]
        XCTAssertTrue(thisChat.waitForExistence(timeout: 5))
        thisChat.tap()
        let menuItem = app.buttons["chat.group-settings"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        XCTAssertTrue(menuItem.isHittable)
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
