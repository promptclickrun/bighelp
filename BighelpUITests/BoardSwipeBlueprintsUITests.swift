import XCTest

/// Swipe left to dismiss on Feed, Ideas and Goals (Today › See all › one bot's board), the
/// Blueprints on each, and Goals by category, in demo mode. BIGHELP_BOARD_EVIDENCE (a folder) also saves light and dark
/// screenshots for review.
final class BoardSwipeBlueprintsUITests: BighelpUITestCase {
    /// Each board's rows reveal their own dismiss action, including a swipe that starts at
    /// the screen's right edge (the root's New chat edge strip used to take it).
    @MainActor
    func testSwipeLeftDismissesOnEveryBoard() throws {
        let app = launch(appearance: "light")
        // Ideas sit two to a row in the bento, so a tile's Not now is in its touch-and-hold menu.
        let cases: [(tab: String, row: XCUIElement, action: String, fromEdge: Bool, holds: Bool)] = [
            ("tab.feed", app.descendants(matching: .any)["board.feed.post.feed-3"], "Clear", true, false),
            ("tab.ideas", app.buttons["board.idea.idea-3"], "Not now", false, true),
            ("tab.goals", app.descendants(matching: .any)["board.goal.goal-4"], "Remove", true, false),
        ]
        for (tab, row, action, fromEdge, holds) in cases {
            openBoard(tab, in: app)
            // Boards are Lists: rows below the fold don't exist until scrolled to.
            _ = app.buttons["board.blueprints"].waitForExistence(timeout: 10)
            scroll(app, until: row)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(tab) shows the item")
            if holds { row.press(forDuration: 1.0) } else { swipeLeft(on: row, in: app, fromEdge: fromEdge) }
            let button = app.buttons[action].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(holds ? "Holding" : "Swiping left on") \(tab) shows \(action)")
            XCTAssertFalse(app.textViews["chat.composer.text"].exists, "The swipe didn't open a new chat")
            save("board-swipe-\(tab)", app)
            button.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "\(action) hides the item")
            XCTAssertTrue(app.buttons["board.undo"].waitForExistence(timeout: 5), "…with Undo")
            app.buttons["board.undo"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo brings it back")
        }
    }

    /// A post cleared on one bot's Feed is gone from All bots and from Today's Feed panel at once.
    /// They kept their own copy of the bot's board until the next read, so the post stayed there
    /// until a pull down.
    @MainActor
    func testAPostClearedOnABotsFeedIsGoneFromAllBotsAndToday() throws {
        let app = launch(appearance: "light")
        openTodayBoard("feed", in: app)
        let inAllBots = app.descendants(matching: .any)["today.boards.item.finance/feed-3"].firstMatch
        XCTAssertTrue(inAllBots.waitForExistence(timeout: 10), "All bots lists the post before it's cleared")
        app.buttons["today.board-page.chip.finance"].firstMatch.tap()
        let row = app.descendants(matching: .any)["board.feed.post.feed-3"]
        _ = app.buttons["board.blueprints"].waitForExistence(timeout: 10)
        scroll(app, until: row)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        swipeLeft(on: row, in: app, fromEdge: false)
        let clear = app.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "Clear hides the post on the bot's Feed")

        app.buttons["today.board-page.chip.all"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["today.board-page.all"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["today.boards.item.finance/feed-1"].firstMatch
            .waitForExistence(timeout: 5), "All bots still lists the bot's other posts")
        XCTAssertFalse(inAllBots.exists, "The cleared post is gone from All bots without a pull down")
        save("board-cleared-all-bots", app)

        app.buttons["today.board-page.back"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["today.boards"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["today.boards.item.finance/feed-3"].firstMatch.exists,
                       "…and from Today's Feed panel")
        save("board-cleared-today", app)
    }

    /// Every post on a bot's Feed has a row of its own, so each one swipes both ways: right for Do
    /// it, which opens the bot's chat to send "Let's do it!" with the post, and left for Clear.
    @MainActor
    func testEveryFeedPostSwipesRightForDoItAndLeftForClear() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openBoard("tab.feed", in: app)
            _ = app.buttons["board.blueprints"].waitForExistence(timeout: 10)
            save("board-feed-rows-\(appearance)", app)
            for id in ["feed-1", "feed-2", "feed-3"] {
                let row = app.descendants(matching: .any)["board.feed.post.\(id)"]
                scroll(app, until: row)
                XCTAssertTrue(row.waitForExistence(timeout: 10), "\(id) is on the Feed")
                swipeLeft(on: row, in: app, fromEdge: false)
                XCTAssertTrue(app.buttons["Clear"].firstMatch.waitForExistence(timeout: 5), "\(id) swipes left for Clear")
                if id == "feed-1" { save("board-feed-swipe-clear-\(appearance)", app) }
                // Put the row back: a tap beside the action closes it.
                swipeRight(on: row, in: app, by: 60)
                swipeRight(on: row, in: app, by: 110)
                XCTAssertTrue(app.buttons["Do it"].firstMatch.waitForExistence(timeout: 5), "\(id) swipes right for Do it")
                if id == "feed-1" { save("board-feed-swipe-do-it-\(appearance)", app) }
                swipeLeft(on: row, in: app, fromEdge: false)
            }
            guard appearance == "light" else { app.terminate(); continue }
            let row = app.descendants(matching: .any)["board.feed.post.feed-1"]
            scroll(app, until: row)
            swipeRight(on: row, in: app, by: 110)
            let doIt = app.buttons["Do it"].firstMatch
            XCTAssertTrue(doIt.waitForExistence(timeout: 5))
            doIt.tap()
            // The demo's chat doesn't take a message sent from outside it, so this checks the way
            // there; the message itself is checked on a real computer.
            XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10), "Do it opens the bot's chat")
            save("board-feed-do-it-chat", app)
            app.terminate()
        }
    }

    /// A blueprint goes to a new chat's message box, nothing sent: one with a blank shows it as a
    /// chip that Send waits for, and one with none is plain text ready to edit.
    @MainActor
    func testBlueprintsGoToTheMessageBoxWithTheirBlanksAsChips() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            for (tab, pick) in [("tab.feed", "feed-marketing-1"), ("tab.ideas", "ideas-productivity-1")] {
                openBoard(tab, in: app)
                let entry = app.buttons["board.blueprints"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10), "Blueprints on \(tab)")
                entry.tap()
                let sheet = app.descendants(matching: .any)["board.blueprints.sheet"]
                XCTAssertTrue(sheet.waitForExistence(timeout: 5))
                save("board-blueprints-\(tab)-\(appearance)", app)
                guard appearance == "light" else {
                    app.buttons["board.blueprints.done"].tap()
                    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
                    continue
                }
                let blueprint = app.buttons["board.blueprint.\(pick)"]
                for _ in 0..<6 where !blueprint.isHittable { sheet.swipeUp() }
                XCTAssertTrue(blueprint.waitForExistence(timeout: 5))
                blueprint.tap()
                XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "A pick closes the sheet")
                let sent = app.descendants(matching: .any)["chat.message.inline-selection"].firstMatch
                let tray = app.descendants(matching: .any)["chat.blueprint.tray"].firstMatch
                if pick == "feed-marketing-1" {
                    XCTAssertTrue(tray.waitForExistence(timeout: 10), "Its blank is a chip to fill in")
                    let send = app.buttons["chat.send"]
                    XCTAssertFalse(send.isEnabled, "Send waits until the blank is filled in")
                    let blank = app.textFields["chat.blueprint.input"]
                    XCTAssertTrue(blank.waitForExistence(timeout: 5))
                    blank.tap()
                    blank.typeText("Acme\n")
                    save("board-blueprint-chips-\(tab)", app)
                    XCTAssertTrue(send.isEnabled)
                    XCTAssertFalse(sent.exists, "Nothing is sent until the person taps Send")
                    send.tap()
                    XCTAssertTrue(sent.waitForExistence(timeout: 20))
                    let shown = NSPredicate(format: "value CONTAINS %@", "post what Acme shipped")
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: sent)],
                                                  timeout: 8), .completed, "The blank is filled in what was sent")
                    XCTAssertTrue(tray.waitForNonExistence(timeout: 5), "The chips go with the message")
                } else {
                    let editor = app.textViews["chat.composer.text"]
                    XCTAssertTrue(editor.waitForExistence(timeout: 10), "It opens a chat")
                    let placed = NSPredicate(format: "value BEGINSWITH %@", "Every 12 hours, look at our recent chats")
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)],
                                                  timeout: 8), .completed, "…with the prompt ready to edit")
                    XCTAssertFalse(tray.exists, "No blanks, no chips")
                    XCTAssertFalse(sent.exists, "Nothing is sent until the person taps Send")
                }
            }
            app.terminate()
        }
    }

    @MainActor
    func testGoalsGroupByCategoryAndStartOneFromTheList() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openBoard("tab.goals", in: app)
            let health = app.descendants(matching: .any)["board.goals.category.health"]
            XCTAssertTrue(health.waitForExistence(timeout: 10), "Goals are grouped by category")
            XCTAssertTrue(app.descendants(matching: .any)["board.goals.category.finance"].exists)
            // The latest goal leads in its own block; Other's heading is further down the card.
            let other = app.descendants(matching: .any)["board.goals.category.other"]
            scroll(app, until: other)
            XCTAssertTrue(other.exists, "A goal without a category shows under Other")
            save("board-goals-categories-\(appearance)", app)
            let create = app.buttons["board.goals.create.relationships"]
            scroll(app, until: create)
            XCTAssertTrue(app.staticTexts["Create a goal"].exists)
            save("board-goals-create-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }
            create.tap()
            let editor = app.textViews["chat.composer.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let placed = NSPredicate(format: "value CONTAINS %@", "under Relationships")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)],
                                          timeout: 8), .completed, "The category's prompt is ready to edit")
            app.terminate()
        }
    }

    /// Let's do it records the idea by its ID (the demo board stands in for the host) and opens
    /// a chat with only the readable text: the ID never reaches the message box.
    @MainActor
    func testLetsDoItOpensAChatWithTheIdeaTitleOnly() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openBoard("tab.ideas", in: app)
            let idea = app.buttons["board.idea.idea-1"]
            XCTAssertTrue(idea.waitForExistence(timeout: 10))
            idea.tap()
            let accept = app.buttons["board.idea.accept"]
            XCTAssertTrue(accept.waitForExistence(timeout: 5))
            save("board-idea-sheet-\(appearance)", app)
            accept.tap()
            let editor = app.textViews["chat.composer.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let placed = NSPredicate(format: "value == %@",
                                     "Yes, go ahead with this idea: “I can plan Sam's birthday dinner end to end”.")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)],
                                          timeout: 8), .completed, "The readable text is ready to send")
            XCTAssertFalse((editor.value as? String ?? "").contains("idea-1"), "The idea's ID stays out of the chat")
            XCTAssertFalse(app.descendants(matching: .any)["board.idea.accept.failed"].exists)
            save("board-idea-lets-do-it-\(appearance)", app)
            app.terminate()
        }
    }

    /// Boards are Lists: rows below the fold exist only once scrolled to. Short drags, so a row
    /// in the middle isn't scrolled past.
    @MainActor private func scroll(_ app: XCUIApplication, until element: XCUIElement) {
        let window = app.windows.firstMatch
        for _ in 0..<12 where !(element.exists && element.isHittable && element.frame.maxY < window.frame.maxY - 140) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -220)))
        }
    }

    @MainActor private func swipeLeft(on row: XCUIElement, in app: XCUIApplication, fromEdge: Bool) {
        let window = app.windows.firstMatch.frame
        let y = row.frame.minY + min(row.frame.height / 2, 30)
        let startX = fromEdge ? window.maxX - 6 : row.frame.midX + row.frame.width / 4
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: startX, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor private func swipeRight(on row: XCUIElement, in app: XCUIApplication, by distance: CGFloat) {
        let y = row.frame.minY + min(row.frame.height / 2, 30)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        // From the middle of the row: a drag from the screen's left edge is the system's Back.
        let start = origin.withOffset(CGVector(dx: row.frame.midX - row.frame.width / 4, dy: y))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    @MainActor private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    /// Today › the panel's board (`tab.feed|ideas|goals`) › See all › the demo's Avery (`finance`):
    /// that bot's whole board.
    @MainActor private func openBoard(_ tab: String, in app: XCUIApplication,
                                      file: StaticString = #filePath, line: UInt = #line) {
        openTodayBoard(tab.replacingOccurrences(of: "tab.", with: ""), in: app, file: file, line: line)
        let bot = app.buttons["today.board-page.chip.finance"].firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "See all has the bot's chip", file: file, line: line)
        bot.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_BOARD_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
