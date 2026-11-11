import XCTest

/// The Needs you deck, an empty board's starters and their chips in the message box, and
/// Settings › Modes' picker, in demo mode. BIGHELP_UX_EVIDENCE (a folder) also saves the screenshots.
final class NeedsYouBlueprintsModesUITests: BighelpUITestCase {
    @MainActor
    func testDeckStartersChipsAndModesDark() throws {
        try walkthrough(appearance: "dark")
    }

    @MainActor
    func testDeckStartersChipsAndModesLight() throws {
        try walkthrough(appearance: "light")
    }

    @MainActor
    private func walkthrough(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-demo-empty-boards", "-demo-needs-you",
            "-loopdy.demo.appearance", appearance,
        ]
        app.launch()

        // Needs you: one tab for each thing waiting.
        let deck = app.descendants(matching: .any)["needs-you.deck"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 15), "The deck opens")
        XCTAssertTrue(app.buttons["needs-you.tab.0"].waitForExistence(timeout: 5), "A tab for each thing waiting")
        save("needs-you-approval-\(appearance)", app)
        app.buttons["needs-you.tab.1"].tap()
        save("needs-you-question-\(appearance)", app)

        // A sign-off waits for the whole file: Approve is off until it has been opened.
        app.buttons["needs-you.tab.2"].tap()
        let approve = app.buttons["needs-you.signoff.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        let showAll = app.buttons["needs-you.signoff.show-all"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 10), "A long file opens in full first")
        XCTAssertFalse(approve.isEnabled, "Approve waits for the whole file")
        save("needs-you-signoff-\(appearance)", app)
        showAll.tap()
        XCTAssertTrue(approve.isEnabled)
        save("needs-you-signoff-whole-file-\(appearance)", app)

        app.buttons["needs-you.later"].tap()
        XCTAssertTrue(deck.waitForNonExistence(timeout: 5), "Later closes the deck")

        // An empty Feed offers starters.
        openRootTab("tab.feed", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["board.feed.empty"].firstMatch.waitForExistence(timeout: 10))
        let starter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "board.starter.")).firstMatch
        XCTAssertTrue(starter.waitForExistence(timeout: 5), "A starter to pick")
        save("empty-feed-starters-\(appearance)", app)

        // A starter goes to the message box with its blank as a chip; Send waits for it.
        starter.tap()
        let tray = app.descendants(matching: .any)["chat.blueprint.tray"].firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "The blank is ready to fill in")
        XCTAssertTrue(app.buttons["chat.blueprint.chip.0"].exists, "The blank is a chip in the message")
        let send = app.buttons["chat.send"]
        XCTAssertFalse(send.isEnabled, "Send waits for the blank")
        save("blueprint-chips-\(appearance)", app)
        let blank = app.textFields["chat.blueprint.input"]
        blank.tap()
        blank.typeText("Acme\n")
        XCTAssertTrue(send.isEnabled)
        save("blueprint-chips-filled-\(appearance)", app)

        // Modes: one picker for the home, and Code mode's own switch.
        openSettings(in: app)
        settingsRow("settings.menu.modes", in: app).tap()
        let chat = app.buttons["settings.mode.chat"]
        let code = app.buttons["settings.mode.code"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.mode.bots"].exists)
        XCTAssertTrue(chat.isSelected)
        let codeMode = app.switches["settings.code-mode"]
        XCTAssertEqual(codeMode.value as? String, "0")
        save("settings-modes-\(appearance)", app)

        code.tap()
        XCTAssertTrue(code.isSelected)
        XCTAssertEqual(codeMode.value as? String, "1", "Picking Code turns Code mode on")
        codeMode.switches.firstMatch.tap()
        XCTAssertTrue(chat.isSelected, "Code mode off goes back to Chat")
        code.tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["code.screen"].waitForExistence(timeout: 10),
                      "Picking Code makes it the home")

        app.terminate()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UX_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
