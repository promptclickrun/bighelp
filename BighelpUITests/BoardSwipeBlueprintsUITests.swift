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

    @MainActor
    func testBlueprintsOnEveryBoardFillTheMessageBox() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            for (tab, first) in [("tab.feed", "feed-productivity-1"), ("tab.ideas", "ideas-productivity-1"),
                                 ("tab.goals", "goals-productivity-1")] {
                openRootTab(tab, in: app)
                let entry = app.buttons["board.blueprints"].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10), "Blueprints on \(tab)")
                entry.tap()
                let sheet = app.descendants(matching: .any)["board.blueprints.sheet"]
                XCTAssertTrue(sheet.waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["Research"].exists || app.buttons["board.blueprint.\(first)"].exists)
                save("board-blueprints-\(tab)-\(appearance)", app)
                guard appearance == "light" else {
                    app.buttons["board.blueprints.done"].tap()
                    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
                    continue
                }
                let blueprint = app.buttons["board.blueprint.\(first)"]
                XCTAssertTrue(blueprint.waitForExistence(timeout: 5))
                blueprint.tap()
                let editor = app.textViews["chat.composer.text"]
                XCTAssertTrue(editor.waitForExistence(timeout: 10), "A blueprint opens a chat")
                let placed = NSPredicate(format: "value BEGINSWITH %@", firstWords[first] ?? "")
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)],
                                              timeout: 8), .completed, "…with the prompt ready to edit, not sent")
                XCTAssertFalse(app.descendants(matching: .any)["chat.message.inline-selection"].exists,
                               "Nothing is sent until the person taps Send")
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

    private let firstWords = [
        "feed-productivity-1": "Every weekday at 7am, post a morning brief",
        "ideas-productivity-1": "Every 12 hours, look at our recent chats",
        "goals-productivity-1": "Make a goal to keep my inbox under 20 unread",
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
