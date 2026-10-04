import XCTest

/// Swipe left to dismiss on Feed, Ideas and Goals, the Blueprints on each, and Goals by
/// category, in demo mode. BIGHELP_BOARD_EVIDENCE (a folder) also saves light and dark
/// screenshots for review.
final class BoardSwipeBlueprintsUITests: BighelpUITestCase {
    /// Each board's rows reveal their own dismiss action, including a swipe that starts at
    /// the screen's right edge (the root's New chat edge strip used to take it).
    @MainActor
    func testSwipeLeftDismissesOnEveryBoard() throws {
        let app = launch(appearance: "light")
        let cases: [(tab: String, row: XCUIElement, action: String, fromEdge: Bool)] = [
            ("tab.feed", app.descendants(matching: .any)["board.feed.post.feed-3"], "Clear", true),
            ("tab.ideas", app.buttons["board.idea.idea-3"], "Not now", false),
            ("tab.goals", app.descendants(matching: .any)["board.goal.goal-4"], "Remove", true),
        ]
        for (tab, row, action, fromEdge) in cases {
            openRootTab(tab, in: app)
            // Boards are Lists: rows below the fold don't exist until scrolled to.
            _ = app.buttons["board.blueprints"].waitForExistence(timeout: 10)
            scroll(app, until: row)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "\(tab) shows the item")
            swipeLeft(on: row, in: app, fromEdge: fromEdge)
            let button = app.buttons[action].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Swiping left on \(tab) shows \(action)")
            XCTAssertFalse(app.textViews["chat.composer.text"].exists, "The swipe didn't open a new chat")
            save("board-swipe-\(tab)", app)
            button.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 5), "\(action) hides the item")
            XCTAssertTrue(app.buttons["board.undo"].waitForExistence(timeout: 5), "…with Undo")
            app.buttons["board.undo"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Undo brings it back")
        }
    }

    /// A blueprint opens a fill-in page: blanks to fill, then Send to agent starts a new chat
    /// that sends it, or Edit in message box leaves it there unsent.
    @MainActor
    func testBlueprintsAskForTheBlanksThenSendOrEdit() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            for (tab, pick, action) in [("tab.feed", "feed-marketing-1", "send"),
                                        ("tab.ideas", "ideas-productivity-1", "edit"),
                                        ("tab.goals", "goals-productivity-1", "send")] {
                openRootTab(tab, in: app)
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
                let send = app.buttons["board.blueprint.fill.send"]
                XCTAssertTrue(send.waitForExistence(timeout: 5), "A blueprint opens its fill-in page")
                if pick == "feed-marketing-1" {
                    XCTAssertFalse(send.isEnabled, "Send waits until the blank is filled in")
                    let blank = app.textFields["board.blueprint.fill.blank.0"]
                    XCTAssertTrue(blank.waitForExistence(timeout: 5))
                    blank.tap()
                    blank.typeText("Acme")
                    XCTAssertTrue(send.isEnabled)
                }
                save("board-blueprint-fill-\(tab)", app)
                let editor = app.textViews["chat.composer.text"]
                if action == "send" {
                    send.tap()
                    let sent = app.descendants(matching: .any)["chat.message.inline-selection"].firstMatch
                    XCTAssertTrue(sent.waitForExistence(timeout: 20), "Send to agent sends it in a new chat")
                    if let words = sentWords[pick] {
                        let shown = NSPredicate(format: "value CONTAINS %@", words)
                        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: sent)],
                                                      timeout: 8), .completed, "…with the blanks filled in")
                    }
                } else {
                    app.buttons["board.blueprint.fill.edit"].tap()
                    XCTAssertTrue(editor.waitForExistence(timeout: 10), "Edit opens a chat")
                    let placed = NSPredicate(format: "value BEGINSWITH %@", "Every 12 hours, look at our recent chats")
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)],
                                                  timeout: 8), .completed, "…with the prompt ready to edit")
                    XCTAssertFalse(app.descendants(matching: .any)["chat.message.inline-selection"].exists,
                                   "Nothing is sent until the person taps Send")
                }
            }
            app.terminate()
        }
    }

    @MainActor
    func testGoalsGroupByCategoryAndStartOneFromTheList() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openRootTab("tab.goals", in: app)
            let health = app.descendants(matching: .any)["board.goals.category.health"]
            XCTAssertTrue(health.waitForExistence(timeout: 10), "Goals are grouped by category")
            XCTAssertTrue(app.descendants(matching: .any)["board.goals.category.finance"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["board.goals.category.other"].exists,
                          "A goal without a category shows under Other")
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
            openRootTab("tab.ideas", in: app)
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

    private let sentWords = [
        "feed-marketing-1": "post what Acme shipped",
        "goals-productivity-1": "Add a goal to my Goals under Productivity",
    ]

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

    @MainActor private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.home.opens-chat", "YES"]
        app.launch()
        return app
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
