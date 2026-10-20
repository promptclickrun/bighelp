import XCTest

/// Simple Bot mode on demo data: the home (your circle, search, +, the primary
/// bot, the rest), Settings, Create New Bot, search, a bot's menu, its chat and
/// its profile, in light and dark. Set BIGHELP_SIMPLE_BOTS_EVIDENCE
/// (TEST_RUNNER_…) to a folder to save the screenshots.
final class SimpleBotsUITests: BighelpUITestCase {
    @MainActor
    func testSimpleBotModeHomeChatAndProfile() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let home = app.descendants(matching: .any)["simple-bots.home"]
            XCTAssertTrue(home.waitForExistence(timeout: 15), "Simple Bot mode opens on its home")
            XCTAssertFalse(app.buttons["home.drawer.open"].exists, "No ☰ in Simple Bot mode")
            XCTAssertFalse(app.descendants(matching: .any)["tabbar.sessions"].exists, "No tab bar")
            let primary = app.buttons["simple-bots.primary"]
            XCTAssertTrue(primary.exists)
            XCTAssertTrue(app.buttons["simple-bots.bot.travel"].exists, "Other bots are listed")
            save("simple-home-\(appearance)", app)

            // Settings: the short sheet, with the way back to all of bighelp.
            app.buttons["simple-bots.settings"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.settings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["simple-bots.settings.mode"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.settings.auto-review"].waitForExistence(timeout: 5),
                          "Auto-review reads the demo host's approvals")
            save("simple-settings-\(appearance)", app)
            app.buttons["simple-bots.settings.close"].tap()

            // Create New Bot.
            app.buttons["simple-bots.new"].tap()
            app.buttons["New Bot"].tap()
            let name = app.textFields["simple-bots.create.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["simple-bots.create.submit"].isEnabled, "Create needs a name")
            app.buttons["simple-bots.shape.hexagon"].tap()
            app.buttons["simple-bots.color.orange"].tap()
            save("simple-create-\(appearance)", app)
            app.buttons["simple-bots.create.close"].tap()

            // Search lists every bot.
            app.buttons["simple-bots.search"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.search.bot.home"].waitForExistence(timeout: 5))
            save("simple-search-\(appearance)", app)
            app.buttons["simple-bots.search.close"].tap()

            // Touch and hold the primary bot.
            primary.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Replace Primary Bot…"].waitForExistence(timeout: 5))
            save("simple-menu-\(appearance)", app)
            app.buttons["Replace Primary Bot…"].tap()
            XCTAssertTrue(app.buttons["simple-bots.primary-pick.travel"].waitForExistence(timeout: 5))
            app.buttons["Cancel"].tap()

            // The primary bot's chat, then its profile from its name.
            primary.tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["chat.new-chat"].exists, "One chat per bot on the home")
            save("simple-chat-\(appearance)", app)
            identity.tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 5))
            app.buttons["simple-bots.shape.star"].tap()
            app.buttons["simple-bots.color.purple"].tap()
            let status = app.staticTexts["simple-bots.profile.mark-status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            save("simple-profile-\(appearance)", app)
            app.swipeUp()
            save("simple-profile-lower-\(appearance)", app)
            app.terminate()
        }
    }

    /// A bot's profile: More avatars opens the full studio with the marks in it, and Save comes back
    /// to the profile; Default Model opens the model and reasoning picker.
    @MainActor
    func testProfileOpensTheStudioAndTheModelPicker() throws {
        let app = launch(appearance: "dark")
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.primary"].tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 5))
        save("simple-profile-rows-dark", app)

        let more = app.buttons["simple-bots.profile.more-avatars"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let bots = app.buttons["avatar.creator.category.bots"]
        XCTAssertTrue(bots.waitForExistence(timeout: 5), "The studio offers the bot marks")
        XCTAssertTrue(app.buttons["avatar.creator.category.bighelp"].exists, "And every other avatar")
        bots.tap()
        // The profile under the sheet has the same picker; these are the studio's.
        let marks = app.descendants(matching: .any)["avatar.creator.bots"]
        XCTAssertTrue(marks.waitForExistence(timeout: 5))
        marks.buttons["simple-bots.shape.heart"].tap()
        marks.buttons["simple-bots.color.teal"].tap()
        save("simple-studio-dark", app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 5),
                      "Save comes back to the profile")
        XCTAssertFalse(app.buttons["avatar.creator.category.bots"].exists)

        let model = app.buttons["simple-bots.profile.default-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "Default Model is under Instructions")
        model.tap()
        XCTAssertTrue(app.navigationBars["Default Model"].waitForExistence(timeout: 5)
                      || app.staticTexts["Default Model"].waitForExistence(timeout: 2))
        save("simple-default-model-dark", app)
    }

    /// A bot's profile: Files and Media after Computer. Files opens a folder in place, Back goes up,
    /// and a file opens in the chat preview; Media shows the bot's photos and videos.
    @MainActor
    func testProfileFilesAndMedia() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let primary = app.buttons["simple-bots.primary"]
            XCTAssertTrue(primary.waitForExistence(timeout: 15))
            primary.tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            let profile = app.descendants(matching: .any)["simple-bots.profile"]
            // A tap while the chat is still sliding in can miss; one more is enough.
            identity.tap()
            if !profile.waitForExistence(timeout: 5) { identity.tap() }
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            let filesTab = app.buttons["simple-bots.profile.tab.files"]
            let mediaTab = app.buttons["simple-bots.profile.tab.media"]
            XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
            XCTAssertTrue(mediaTab.exists)
            XCTAssertLessThan(filesTab.frame.minX, mediaTab.frame.minX, "Files, then Media")

            filesTab.tap()
            let items = app.buttons.matching(identifier: "simple-bots.files.item")
            XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10), "The bot's folder lists its files")
            app.swipeUp()
            save("simple-files-\(appearance)", app)

            // Markdown reads rendered, as in chats.
            let notes = items.matching(NSPredicate(format: "label BEGINSWITH 'Notes.md'")).firstMatch
            XCTAssertTrue(notes.exists)
            notes.tap()
            let done = app.buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10), "The file opens in the preview")
            XCTAssertTrue(app.descendants(matching: .any)["chat.attachment.markdown.mode"].waitForExistence(timeout: 5))
            save("simple-files-markdown-\(appearance)", app)
            done.tap()

            let reports = items.matching(NSPredicate(format: "label BEGINSWITH 'Reports'")).firstMatch
            XCTAssertTrue(reports.waitForExistence(timeout: 5))
            reports.tap()
            let up = app.buttons["simple-bots.files.up"]
            XCTAssertTrue(up.waitForExistence(timeout: 5), "A folder opens in place, with Back above it")
            save("simple-files-folder-\(appearance)", app)

            let plan = items.matching(NSPredicate(format: "label BEGINSWITH 'Lisbon trip options'")).firstMatch
            XCTAssertTrue(plan.waitForExistence(timeout: 5))
            plan.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10), "The PDF opens in the preview")
            sleep(2)
            save("simple-files-preview-\(appearance)", app)
            // Quick Look draws out of process, so these screenshots miss it: hold for `simctl io`.
            if let hold = ProcessInfo.processInfo.environment["BIGHELP_FILES_PREVIEW_HOLD"].flatMap(UInt32.init) {
                sleep(hold)
            }
            done.tap()
            XCTAssertTrue(up.waitForExistence(timeout: 5))
            up.tap()
            XCTAssertTrue(reports.waitForExistence(timeout: 5), "Back goes up to the top folder")

            app.swipeDown()
            mediaTab.tap()
            let tile = app.buttons["board.media.item"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 10), "Media shows the bot's photos and videos")
            sleep(1)
            save("simple-media-\(appearance)", app)
            tile.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10), "A picture opens in the preview")
            sleep(2)
            save("simple-media-preview-\(appearance)", app)
            if let hold = ProcessInfo.processInfo.environment["BIGHELP_FILES_PREVIEW_HOLD"].flatMap(UInt32.init) {
                sleep(hold)
            }
            done.tap()
            app.terminate()
        }
    }

    /// Each bot's Files tab is its own folder: Mina's shows her trip, not Avery's budget.
    @MainActor
    func testEachBotsFilesAreItsOwnFolder() throws {
        let app = launch(appearance: "light")
        let mina = app.buttons["simple-bots.bot.travel"]
        XCTAssertTrue(mina.waitForExistence(timeout: 15))
        mina.tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        identity.tap()
        if !profile.waitForExistence(timeout: 5) { identity.tap() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        app.buttons["simple-bots.profile.tab.files"].tap()
        let items = app.buttons.matching(identifier: "simple-bots.files.item")
        let trip = items.matching(NSPredicate(format: "label BEGINSWITH 'Lisbon trip'")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 10), "Mina's own folder")
        XCTAssertFalse(items.matching(NSPredicate(format: "label BEGINSWITH 'Budget'")).firstMatch.exists,
                       "Not Avery's folder")
        app.swipeUp()
        save("simple-files-other-bot", app)
        trip.tap()
        let itinerary = items.matching(NSPredicate(format: "label BEGINSWITH 'Itinerary.md'")).firstMatch
        XCTAssertTrue(itinerary.waitForExistence(timeout: 5))
        itinerary.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "Her file opens in the preview")
        save("simple-files-other-bot-preview", app)
    }

    /// New Bot's Templates: the picker with My Templates on top (the demo computer's saved one, and
    /// its broken one hidden), a template's fields, the attached chip and taking it off. Then a bot's
    /// Share: name it, Save, and it's one of My Templates.
    @MainActor
    func testTemplatesInNewBotAndSavingABotAsATemplate() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
            app.buttons["simple-bots.new"].tap()
            app.buttons["New Bot"].tap()
            let name = app.textFields["simple-bots.create.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            let templates = app.buttons["simple-bots.create.templates"]
            XCTAssertTrue(templates.waitForExistence(timeout: 5), "Templates sits at the top right")
            name.tap()
            name.typeText("Juniper")
            save("templates-create-\(appearance)", app)

            templates.tap()
            let mine = app.descendants(matching: .any)["agent.templates.mine"]
            XCTAssertTrue(mine.waitForExistence(timeout: 10), "My Templates comes first")
            XCTAssertTrue(app.staticTexts["agent.templates.mine.skipped"].exists, "The broken one is hidden, not the list")
            let saved = app.buttons["agent.templates.mine-3d2b7c1e-5a4f-4b6d-9e8c-1f2a3b4c5d6e"]
            XCTAssertTrue(saved.exists)
            XCTAssertTrue(app.descendants(matching: .any)["agent.templates.section.productivity"].exists,
                          "The catalog's templates are still there, by topic")
            save("templates-picker-\(appearance)", app)
            saved.tap()

            let town = app.textFields["agent.template-form.field.home_town"]
            XCTAssertTrue(town.waitForExistence(timeout: 10), "Its fill-in fields come first")
            town.tap()
            town.typeText("Porto")
            app.buttons["agent.template-form.continue"].tap()
            let chip = app.descendants(matching: .any)["simple-bots.create.template"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "The template shows as a chip")
            XCTAssertEqual(chip.label, "Template: Weekend Planner")
            XCTAssertTrue(app.staticTexts["simple-bots.create.template-note"].exists)
            XCTAssertEqual(name.value as? String, "Juniper")
            save("templates-attached-\(appearance)", app)
            app.buttons["simple-bots.create.template.remove"].tap()
            XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "Its x takes it off")
            XCTAssertFalse(app.staticTexts["simple-bots.create.template-note"].exists)
            app.buttons["simple-bots.create.close"].tap()

            // A bot's Share saves it as a template on the computer.
            app.buttons["simple-bots.primary"].tap()
            let identity = app.buttons["chat.identity"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            identity.tap()
            let share = app.buttons["simple-bots.profile.template"]
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            share.tap()
            let templateName = app.textFields["simple-bots.template.name"]
            XCTAssertTrue(templateName.waitForExistence(timeout: 5))
            // The bot's name is filled in; at the end of it, so every delete removes a letter.
            templateName.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            if let value = templateName.value as? String, !value.isEmpty {
                templateName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
            }
            templateName.typeText("Budget Buddy")
            save("templates-share-\(appearance)", app)
            app.buttons["simple-bots.template.save"].tap()
            XCTAssertTrue(app.alerts["Saved as a template"].waitForExistence(timeout: 10))
            save("templates-saved-\(appearance)", app)
            app.alerts.buttons["OK"].tap()
            app.terminate()
        }
    }

    /// A pinned bot joins the primary one in the top row, and goes back to the list when unpinned.
    @MainActor
    func testPinnedBotsJoinTheTopRow() throws {
        let app = launch(appearance: "dark")
        let listed = app.buttons["simple-bots.bot.travel"]
        XCTAssertTrue(listed.waitForExistence(timeout: 15))
        listed.press(forDuration: 1.2)
        app.buttons["Pin"].tap()
        let pinned = app.buttons["simple-bots.pinned.travel"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 5), "Pinned bots sit beside the primary one")
        XCTAssertFalse(listed.exists, "And leave the list")
        save("simple-home-pinned-dark", app)
        pinned.press(forDuration: 1.2)
        app.buttons["Unpin"].tap()
        XCTAssertTrue(listed.waitForExistence(timeout: 5), "Unpinned, it's back in the list")
    }

    /// Touch and hold a bot: Rearrange (no Save as Template; Hide is under More). Rearrange lets the top
    /// bots be dragged (the primary bot too); Save keeps the order, Cancel drops it.
    @MainActor
    func testRearrangeReordersTheListAndTheTop() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", "dark",
                               // Each run starts with no saved order, and keeps its own out of later runs.
                               "-bighelp.simple-bots.order", "{}"]
        app.launch()
        let rows = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'simple-bots.bot.' OR identifier BEGINSWITH 'simple-bots.group.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15))
        let bots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'simple-bots.bot.'"))
        let draggedID = bots.element(boundBy: bots.count - 1).identifier
        let agentID = String(draggedID.dropFirst("simple-bots.bot.".count))

        // Pin it, so the top has two bots to arrange.
        app.buttons[draggedID].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Rearrange"].waitForExistence(timeout: 5), "The menu offers Rearrange")
        XCTAssertFalse(app.buttons["Save as Template"].exists, "Save as Template is gone")
        XCTAssertFalse(app.buttons["Hide"].exists, "Hide moved into More")
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Hide"].waitForExistence(timeout: 5), "Hide is at the bottom of More")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        let listed = app.buttons[draggedID]
        XCTAssertTrue(listed.waitForExistence(timeout: 5))
        listed.press(forDuration: 1.2)
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.buttons["simple-bots.pinned.\(agentID)"].waitForExistence(timeout: 5))

        // A bot still in the list moves up; the pinned one goes before the primary bot.
        let other = bots.element(boundBy: bots.count - 1).identifier
        app.buttons[other].press(forDuration: 1.2)
        app.buttons["Rearrange"].tap()
        let saveButton = app.buttons["simple-bots.rearrange.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Rearrange shows Save")
        save("simple-rearrange-dark", app)
        // The list's rows use the system's reorder handles, which the test can't drive; the top bots drag here.
        let pinned = app.descendants(matching: .any)["simple-bots.pinned.\(agentID)"]
        let primary = app.descendants(matching: .any)["simple-bots.primary"]
        XCTAssertGreaterThan(pinned.frame.minX, primary.frame.minX)
        pinned.press(forDuration: 0.1, thenDragTo: primary, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitUntil { pinned.frame.minX < primary.frame.minX }, "On top, the dragged bot goes first")
        save("simple-rearranged-dark", app)
        saveButton.tap()
        XCTAssertTrue(app.buttons["simple-bots.search"].waitForExistence(timeout: 5), "Save ends rearranging")
        XCTAssertLessThan(app.buttons["simple-bots.pinned.\(agentID)"].frame.minX, app.buttons["simple-bots.primary"].frame.minX)

        // Cancel drops a change.
        app.buttons["simple-bots.pinned.\(agentID)"].press(forDuration: 1.2)
        app.buttons["Rearrange"].tap()
        let pinnedAgain = app.descendants(matching: .any)["simple-bots.pinned.\(agentID)"]
        pinnedAgain.press(forDuration: 0.1, thenDragTo: app.descendants(matching: .any)["simple-bots.primary"],
                          withVelocity: .slow, thenHoldForDuration: 0.3)
        app.buttons["simple-bots.rearrange.cancel"].tap()
        XCTAssertTrue(app.buttons["simple-bots.search"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["simple-bots.pinned.\(agentID)"].frame.minX, app.buttons["simple-bots.primary"].frame.minX,
                          "Cancel keeps the saved order")

        app.buttons["simple-bots.pinned.\(agentID)"].press(forDuration: 1.2)
        app.buttons["Unpin"].tap()
        XCTAssertTrue(app.buttons[draggedID].waitForExistence(timeout: 5))
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

    /// The message box: voice mode's pill inside it, Send in its place once there's text. Voice opens as a
    /// bar over the chat, which stays in use, and End closes the bar. Needs the microphone allowed for
    /// bighelp on the simulator (`simctl privacy … grant microphone`).
    @MainActor
    func testVoiceIsABarOverTheChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", "dark",
                               "-loopdy.voice.conversation-mode", "turnBased", "-bighelp.voice.transcription", "hermes"]
        app.launch()
        XCTAssertTrue(app.buttons["simple-bots.primary"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.primary"].tap()
        let voice = app.buttons["chat.voice"]
        XCTAssertTrue(voice.waitForExistence(timeout: 10))
        save("simple-composer-idle-dark", app)

        voice.tap()
        let bar = app.descendants(matching: .any)["simple-bots.voice"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "Voice is a bar over the chat")
        XCTAssertFalse(app.descendants(matching: .any)["voice.screen"].exists, "Not the voice screen")
        XCTAssertTrue(app.buttons["simple-bots.voice.microphone"].exists)
        XCTAssertTrue(app.buttons["chat.attachment"].isHittable, "The chat stays in use")
        save("simple-voice-bar-dark", app)
        app.buttons["simple-bots.voice.end"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: bar)
        waitForExpectations(timeout: 10)

        let input = app.textViews.firstMatch
        input.tap()
        input.typeText("Text 123")
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["chat.voice"].exists, "Typing swaps voice mode for Send")
        XCTAssertFalse(app.buttons["chat.composer.expand"].exists, "One line keeps the box full width")
        save("simple-composer-typing-dark", app)
        input.typeText(" and a longer draft that wraps onto a second line in the box")
        XCTAssertTrue(app.buttons["chat.composer.expand"].waitForExistence(timeout: 3),
                      "Expand sits beside the box once the draft wraps")
    }

    @MainActor
    func testTurningSimpleBotModeOffComesBackToBighelp() throws {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.settings"].tap()
        let mode = app.switches["simple-bots.settings.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()
        // The full Settings takes over the sheet; close it.
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 10), "☰ is back")
        XCTAssertFalse(app.descendants(matching: .any)["simple-bots.home"].exists)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIMPLE_BOTS_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
