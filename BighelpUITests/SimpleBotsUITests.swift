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
