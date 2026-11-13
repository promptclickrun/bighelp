import XCTest

/// The Needs you deck, and an empty board's starters (a bot's Feed, from Today › See all) and their
/// chips in the message box, in demo mode. BIGHELP_UX_EVIDENCE (a folder) also saves the screenshots.
final class NeedsYouBlueprintsModesUITests: BighelpUITestCase {
    @MainActor
    func testDeckStartersAndChipsDark() throws {
        try walkthrough(appearance: "dark")
    }

    @MainActor
    func testDeckStartersAndChipsLight() throws {
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

        // An empty Feed offers starters: one bot's, from Today › See all.
        openTodayBoard("feed", in: app)
        let bot = app.buttons["today.board-page.chip.finance"].firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "See all lists the bots")
        bot.tap()
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
