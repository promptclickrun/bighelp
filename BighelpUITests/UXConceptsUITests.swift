import XCTest

/// Verifies 1B (Needs You Decision Deck), 2A & 2B (empty-board starter Blueprints + inline
/// composer fill-in chips), and 3A (3-way Home Experience selector in Settings › Modes).
final class UXConceptsUITests: BighelpUITestCase {
    @MainActor
    func testNeedsYouDeckEmptyBoardStarterChipsAndModesSelectorDark() throws {
        try runConceptWalkthrough(appearance: "dark")
    }

    @MainActor
    func testNeedsYouDeckEmptyBoardStarterChipsAndModesSelectorLight() throws {
        try runConceptWalkthrough(appearance: "light")
    }

    @MainActor
    private func runConceptWalkthrough(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures",
            "-disable-demo-delays",
            "-demo-empty-boards",
            "-demo-needs-you",
            "-loopdy.demo.appearance", appearance,
        ]
        app.launch()

        // 1B: Needs You Decision Deck opens with waiting items and tabs.
        let deck = app.descendants(matching: .any)["needs-you.deck"].firstMatch
        XCTAssertTrue(deck.waitForExistence(timeout: 15), "Needs You Deck opens")
        XCTAssertTrue(app.buttons["needs-you.tab.0"].waitForExistence(timeout: 5), "Shows numbered triage tabs")
        save("1B-needs-you-\(appearance)", app)

        if app.buttons["needs-you.tab.1"].exists {
            app.buttons["needs-you.tab.1"].tap()
            save("1B-needs-you-tab2-\(appearance)", app)
        }
        if app.buttons["needs-you.tab.2"].exists {
            app.buttons["needs-you.tab.2"].tap()
            save("1B-needs-you-tab3-\(appearance)", app)
        }
        app.buttons["needs-you.later"].tap()
        XCTAssertTrue(deck.waitForNonExistence(timeout: 5), "Later closes the deck")

        // 2A: Empty Feed board shows starter Blueprint cards with highlighted fill-in slots.
        openRootTab("tab.feed", in: app)
        let emptyFeed = app.descendants(matching: .any)["board.feed.empty"].firstMatch
        XCTAssertTrue(emptyFeed.waitForExistence(timeout: 10), "Empty Feed shows starter blueprints")
        let firstStarter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "board.starter.")).firstMatch
        XCTAssertTrue(firstStarter.waitForExistence(timeout: 5), "Starter blueprint card is tappable")
        save("2A-empty-feed-starters-\(appearance)", app)

        // 2B: Tapping a starter opens the chat with inline fill-in chips and the quick-fill tray.
        firstStarter.tap()
        let tray = app.descendants(matching: .any)["chat.blueprint.tray"].firstMatch
        XCTAssertTrue(tray.waitForExistence(timeout: 10), "Composer shows inline Blueprint quick-fill tray")
        XCTAssertTrue(app.buttons["chat.blueprint.chip.0"].exists, "Inline chip renders inside composer")
        save("2B-composer-chips-\(appearance)", app)

        let preset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.blueprint.preset.")).firstMatch
        if preset.waitForExistence(timeout: 3) {
            preset.tap()
            save("2B-composer-chip-filled-\(appearance)", app)
        }

        // 3A: Settings › Modes presents the unified 3-way Home Experience selector.
        openSettings(in: app)
        settingsRow("settings.menu.modes", in: app).tap()
        let botsCard = app.buttons["settings.mode.bots"]
        let chatCard = app.buttons["settings.mode.chat"]
        let codeCard = app.buttons["settings.mode.code"]
        XCTAssertTrue(botsCard.waitForExistence(timeout: 5))
        XCTAssertTrue(chatCard.exists)
        XCTAssertTrue(codeCard.exists)
        XCTAssertTrue(chatCard.isSelected)
        save("3A-settings-modes-\(appearance)", app)

        codeCard.tap()
        XCTAssertTrue(codeCard.isSelected)
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["code.screen"].waitForExistence(timeout: 10),
                      "Picking Code switches home to Code mode")

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
