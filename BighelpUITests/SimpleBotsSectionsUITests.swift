import XCTest

/// Bots mode's sections and group chats on demo data: + makes a section, Move to Section files a
/// bot, the card opens the section's page, and deleting it keeps its bots; New Group Chat makes one
/// and Pin puts it on top. Set BIGHELP_SIMPLE_BOTS_EVIDENCE (TEST_RUNNER_…) to a folder to save the
/// screenshots.
final class SimpleBotsSectionsUITests: BighelpUITestCase {
    @MainActor
    func testMakingASectionMovingABotOpeningItAndDeletingIt() throws {
        let app = launch(appearance: "light")
        let travel = app.buttons["simple-bots.bot.travel"]
        XCTAssertTrue(travel.waitForExistence(timeout: 15))
        XCTAssertFalse(sectionCards(in: app).firstMatch.exists, "No sections: no Sections area")
        save("sections-none-light", app)

        // + is a short menu: New Bot, then New Section (this demo computer can't make group chats).
        app.buttons["simple-bots.new"].tap()
        // Menu items go by their titles.
        let newBot = app.buttons["New Bot"], newSection = app.buttons["New Section"]
        XCTAssertTrue(newSection.waitForExistence(timeout: 5))
        XCTAssertTrue(newBot.exists)
        XCTAssertFalse(app.buttons["New Group Chat"].exists, "Nothing gray: New Group Chat is left out")
        XCTAssertLessThan(newBot.frame.midY, newSection.frame.midY)
        save("sections-plus-menu-light", app)
        newSection.tap()

        let name = app.textFields["simple-bots.section.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Trips")
        app.buttons["simple-bots.section.member.bot:travel"].tap()
        XCTAssertEqual(app.buttons["simple-bots.section.member.bot:travel"].value as? String, "Selected")
        save("sections-new-section-light", app)
        app.buttons["simple-bots.section.save"].tap()

        let card = app.buttons["simple-bots.section.Trips"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "The new section shows as a card")
        XCTAssertTrue(waitUntil { !app.buttons["simple-bots.bot.travel"].exists }, "Its bot leaves the list")
        XCTAssertTrue(card.label.contains("1 bot"))

        // Move to Section from a bot's menu.
        let jordan = app.buttons["simple-bots.bot.home"]
        jordan.press(forDuration: 1.2)
        tapMenuAction("Move to Section", in: app)
        tapMenuAction("Trips", in: app)
        XCTAssertTrue(waitUntil { card.label.contains("2 bots") }, "Jordan joins Trips")
        XCTAssertFalse(jordan.exists)
        save("sections-home-light", app)

        // The card opens the section's page, with its bots as the home lists them.
        card.tap()
        let page = app.descendants(matching: .any)["simple-bots.section.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["simple-bots.section.title"].label, "Trips")
        XCTAssertTrue(app.buttons["simple-bots.bot.travel"].exists)
        XCTAssertTrue(app.buttons["simple-bots.bot.home"].exists)
        XCTAssertTrue(app.buttons["simple-bots.section.add"].exists, "Add Bots or Group Chats is the last row")
        save("sections-page-light", app)

        // Delete asks first, and keeps the bots.
        app.buttons["simple-bots.section.more"].tap()
        tapMenuAction("Delete Section", in: app)
        let confirm = app.buttons.matching(identifier: "simple-bots.section.delete.confirm").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Delete “Trips”?"].exists)
        confirm.tap()
        XCTAssertTrue(app.buttons["simple-bots.bot.travel"].waitForExistence(timeout: 5), "Back home, Mina is in the list")
        XCTAssertTrue(app.buttons["simple-bots.bot.home"].waitForExistence(timeout: 5), "and so is Jordan")
        XCTAssertFalse(card.exists)
        XCTAssertFalse(sectionCards(in: app).firstMatch.exists)
    }

    /// New Group Chat from +, on a demo computer that can make group chats; then Pin puts it on top.
    @MainActor
    func testMakingAndPinningAGroupChat() throws {
        let app = launch(appearance: "dark", extra: ["-preview-group-create"])
        XCTAssertTrue(app.buttons["simple-bots.bot.travel"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.new"].tap()
        let newGroup = app.buttons["New Group Chat"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["New Bot"].frame.midY, newGroup.frame.midY)
        XCTAssertLessThan(newGroup.frame.midY, app.buttons["New Section"].frame.midY)
        newGroup.tap()

        let title = app.textFields["bot-mode.create.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Trip planning\n")
        app.buttons["bot-mode.create.participant.travel"].tap()
        app.buttons["bot-mode.create.participant.home"].tap()
        app.buttons["bot-mode.create.submit"].tap()
        let back = app.buttons["chat.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The new group chat opens")
        back.tap()

        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'simple-bots.group.' AND label CONTAINS 'Trip planning'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "It's on the home")
        row.press(forDuration: 1.2)
        let labels = ["Pin", "Rearrange", "Move to Section", "Mark Unread", "Group Settings", "Hide", "Delete Group Chat"]
        for label in labels { XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Group chat action: \(label)") }
        for (before, after) in zip(labels, labels.dropFirst()) {
            XCTAssertLessThan(app.buttons[before].frame.midY, app.buttons[after].frame.midY, "\(before) before \(after)")
        }
        save("sections-group-menu-dark", app)
        tapMenuAction("Pin", in: app)

        let pinned = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'simple-bots.pinned.group:'")).firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "A pinned group chat sits on top with the pinned bots")
        XCTAssertTrue(pinned.label.contains("Trip planning"))
        XCTAssertFalse(row.exists, "and leaves the list")
        save("sections-group-pinned-dark", app)
        pinned.press(forDuration: 1.2)
        tapMenuAction("Unpin", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    /// The demo's sections, for screenshots in light, dark and at a large text size: the home, a
    /// section's page, Edit Sections and Edit Members.
    @MainActor
    func testSectionScreens() throws {
        for (appearance, size) in [("light", nil), ("dark", nil), ("light", "AccessibilityXXL")] as [(String, String?)] {
            let suffix = appearance + (size.map { "-" + $0 } ?? "")
            let app = launch(appearance: appearance, extra: ["-test-bot-sections", "-preview-agent-groups"]
                             + (size.map { ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\($0)"] } ?? []))
            let card = app.buttons["simple-bots.section.Home life"]
            XCTAssertTrue(card.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["simple-bots.section.Work"].exists, "Mina is in Work on this computer")
            save("sections-demo-home-\(suffix)", app)

            card.press(forDuration: 1.2)
            for label in ["Open", "Rename", "Edit Members", "Edit Sections", "Delete Section"] {
                XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 3), "Section action: \(label)")
            }
            tapMenuAction("Edit Sections", in: app)
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.sections.edit"].waitForExistence(timeout: 5))
            save("sections-edit-\(suffix)", app)
            app.buttons["simple-bots.sections.cancel"].tap()

            card.tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.section.page"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["simple-bots.bot.home"].exists)
            save("sections-demo-page-\(suffix)", app)
            app.buttons["simple-bots.section.add"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.section.members"].waitForExistence(timeout: 5))
            save("sections-members-\(suffix)", app)
            app.buttons["simple-bots.section.cancel"].tap()
            app.terminate()
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance,
                               "-bighelp.simple-bots.order", "{}"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func sectionCards(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'simple-bots.section.' AND identifier != 'simple-bots.section.page'"))
    }

    @MainActor
    private func tapMenuAction(_ title: String, in app: XCUIApplication) {
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Menu action: \(title)")
        var frame = CGRect.zero
        var unchangedSince = Date()
        XCTAssertTrue(waitUntil {
            guard action.isHittable else { unchangedSince = Date(); return false }
            let next = action.frame
            if next != frame { frame = next; unchangedSince = Date() }
            return Date().timeIntervalSince(unchangedSince) >= 0.5
        }, "Wait for the menu to settle before tapping")
        action.tap()
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIMPLE_BOTS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
