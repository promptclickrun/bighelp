import XCTest

/// Projects and the Feed/Ideas/Goals actions in demo mode. BIGHELP_PROJECTS_EVIDENCE
/// (a folder) also saves light and dark screenshots for review.
final class ProjectsAndBoardUITests: BighelpUITestCase {
    @MainActor
    func testProjectsListOpensAProjectItsChatsAndANewChatInIt() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openProjects(in: app)
            let card = app.buttons["projects.card.loopdy"]
            XCTAssertTrue(card.waitForExistence(timeout: 10), "The sample project is listed")
            XCTAssertTrue(app.buttons["projects.card.home"].exists)
            save("projects-1-list-\(appearance)", app)
            card.tap()
            let chat = app.buttons["project.chat.demo-project-1"]
            XCTAssertTrue(chat.waitForExistence(timeout: 10), "The project's chats are listed")
            XCTAssertTrue(app.descendants(matching: .any)["project.folders"].exists, "…and its folders")
            save("projects-2-detail-\(appearance)", app)
            if appearance == "light" {
                chat.tap()
                XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10), "A project chat opens")
                app.buttons["chat.back"].tap()
                let newChat = app.buttons["project.new-chat"]
                XCTAssertTrue(newChat.waitForExistence(timeout: 10), "Back returns to the project")
                newChat.tap()
                XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10), "A new chat opens")
            }
            app.terminate()
        }
    }

    @MainActor
    func testNewProjectShowsItsDescription() throws {
        let app = launch(appearance: "light")
        openProjects(in: app)
        app.buttons["projects.new"].tap()
        let name = app.textFields["hermes-workspaces.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Garden")
        app.textFields["hermes-workspaces.create.summary"].tap()
        app.textFields["hermes-workspaces.create.summary"].typeText("Plants and watering")
        app.textFields["hermes-workspaces.create.path"].tap()
        app.textFields["hermes-workspaces.create.path"].typeText("/Users/demo/Projects/garden-planner")
        save("projects-3-new", app)
        app.buttons["hermes-workspaces.create.submit"].tap()
        XCTAssertTrue(app.buttons["projects.card.fixture-garden"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Plants and watering"].exists)
    }

    @MainActor
    func testBoardThumbsLongPressUndoAndIdeaToGoal() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let feedTab = app.buttons["tab.feed"]
            XCTAssertTrue(feedTab.waitForExistence(timeout: 10))
            XCTAssertEqual(feedTab.value as? String, "New", "Unseen Feed posts show on the tab")
            feedTab.tap()
            // Checked first: posts count as seen a moment after the Feed opens.
            XCTAssertTrue(app.descendants(matching: .any)["board.unread.feed-1"].waitForExistence(timeout: 5),
                          "A new post has a dot")
            let post = app.descendants(matching: .any)["board.feed.post.feed-2"]
            XCTAssertTrue(post.waitForExistence(timeout: 10))
            save("board-1-feed-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }

            let down = post.buttons["board.feed.thumbs-down"]
            down.tap()
            XCTAssertTrue(app.buttons["Too frequent"].waitForExistence(timeout: 5), "Less like this? offers reasons")
            save("board-2-less-like-this", app)
            app.buttons["Too frequent"].tap()
            wait(for: [expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: down)], timeout: 5)

            // Held on its Markdown text: the post's center is its link preview, which has its own menu.
            post.staticTexts["The city approved the waterfront park"].press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5), "The long-press menu opens")
            XCTAssertTrue(app.buttons["Mark as unread"].exists || app.buttons["Mark as read"].exists)
            save("board-3-long-press", app)
            app.buttons["Delete"].tap()
            XCTAssertTrue(app.buttons["board.undo"].waitForExistence(timeout: 5))
            XCTAssertTrue(post.waitForNonExistence(timeout: 5))
            save("board-4-undo", app)
            app.buttons["board.undo"].tap()
            XCTAssertTrue(post.waitForExistence(timeout: 5), "Undo brings it back")
            // Seen posts lose their dot.
            XCTAssertTrue(app.descendants(matching: .any)["board.unread.feed-1"].waitForNonExistence(timeout: 6))

            app.buttons["tab.ideas"].tap()
            let idea = app.buttons["board.idea.idea-3"]
            XCTAssertTrue(idea.waitForExistence(timeout: 10))
            idea.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Turn into a goal"].waitForExistence(timeout: 5))
            app.buttons["Turn into a goal"].tap()
            XCTAssertTrue(idea.waitForNonExistence(timeout: 5))
            app.buttons["tab.goals"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["board.goal.goal-from-idea-3"].waitForExistence(timeout: 10))
            save("board-5-goal", app)
            app.terminate()
        }
    }

    /// Agents write Feed posts in Markdown (the plugin's `bighelp_board` says so). Headings, lists
    /// and quotes show as such, never as raw `###` or `-` lines.
    @MainActor
    func testFeedPostsShowMarkdown() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let feedTab = app.buttons["tab.feed"]
            XCTAssertTrue(feedTab.waitForExistence(timeout: 10))
            feedTab.tap()
            let post = app.descendants(matching: .any)["board.feed.post.feed-2"]
            XCTAssertTrue(post.waitForExistence(timeout: 10))
            XCTAssertTrue(post.staticTexts["Tonight's picks"].exists, "The heading is its own line, without ###")
            XCTAssertTrue(post.staticTexts["A new battery chemistry doubles e-bike range"].exists, "Each list item stands alone")
            XCTAssertTrue(post.staticTexts["The city approved the waterfront park"].exists)
            XCTAssertTrue(post.staticTexts["Worth a look before the weekend."].exists, "The quote shows without >")
            let raw = NSPredicate(format: "label CONTAINS '###' OR label BEGINSWITH '- ' OR label CONTAINS '**' OR label BEGINSWITH '>'")
            XCTAssertEqual(post.staticTexts.matching(raw).count, 0, "No raw Markdown shows")
            save("board-feed-markdown-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.home.opens-chat", "YES"]
        app.launch()
        return app
    }

    @MainActor private func openProjects(in app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.menu", "home.drawer.open"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let projects = app.buttons["menu.projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 5), "Projects is in the menu")
        projects.tap()
        XCTAssertTrue(app.descendants(matching: .any)["projects.screen"].waitForExistence(timeout: 10))
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PROJECTS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
