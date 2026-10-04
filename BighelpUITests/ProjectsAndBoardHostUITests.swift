import XCTest

/// Projects and Feed/Ideas/Goals feedback against a real, isolated Hermes host
/// with the bighelp plugin (Scripts/HostSignInMatrixProbe.py --modes features
/// --plugin …). The probe seeds the board and checks afterwards that the
/// thumbs down and its reason reached the host. Skipped without the probe.
final class ProjectsAndBoardHostUITests: BighelpUITestCase {
    @MainActor
    func testBoardFeedbackAndProjectsOnARealHost() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes features")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "features" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 30), "The agent's chat opens")

        // The seeded posts are new: the Feed tab says so before it's opened.
        let feedTab = app.buttons["tab.feed"]
        XCTAssertTrue(feedTab.waitForExistence(timeout: 10))
        let newOnTab = expectation(for: NSPredicate(format: "value == %@", "New"), evaluatedWith: feedTab)
        wait(for: [newOnTab], timeout: 20)
        feedTab.tap()
        let stockTips = app.descendants(matching: .any)["board.feed.post.probe-stock-tips"]
        XCTAssertTrue(stockTips.waitForExistence(timeout: 20), "The host's Feed shows")
        save("features-1-feed", app)

        // Coming back to the app on the Feed: the connection closes in the background, then
        // reconnects and learns the plugin's features again. The posts stay, and it never says
        // the plugin is older in between (it used to, until you left the tab and came back).
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(35) // past the 25-second grace: the app closes its connection
        app.activate()
        let older = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "older bighelp plugin")).firstMatch
        var sawOlder = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !sawOlder {
            sawOlder = older.exists
            if !sawOlder { Thread.sleep(forTimeInterval: 0.2) }
        }
        if sawOlder { save("features-1b-older-plugin-after-return", app) }
        XCTAssertFalse(sawOlder, "Coming back never says the plugin is older")
        XCTAssertTrue(stockTips.waitForExistence(timeout: 10), "The posts are there after coming back")
        save("features-1c-feed-after-return", app)

        // Thumbs down with a reason (the probe checks the host kept both).
        let thumbsDown = stockTips.buttons["board.feed.thumbs-down"]
        XCTAssertTrue(thumbsDown.waitForExistence(timeout: 5))
        thumbsDown.tap()
        let reason = app.buttons["Not relevant"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "Less like this? asks why")
        save("features-2-less-like-this", app)
        reason.tap()
        XCTAssertTrue(thumbsDown.waitForExistence(timeout: 5))
        let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: thumbsDown)
        wait(for: [selected], timeout: 10)

        // Long press: delete, then undo.
        let news = app.descendants(matching: .any)["board.feed.post.probe-ai-news"]
        XCTAssertTrue(news.waitForExistence(timeout: 5))
        news.press(forDuration: 1.2)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "The long-press menu opens")
        save("features-3-long-press", app)
        delete.tap()
        let undo = app.buttons["board.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Delete offers Undo")
        XCTAssertTrue(news.waitForNonExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(news.waitForExistence(timeout: 10), "Undo brings the post back")

        // An idea becomes a goal.
        app.buttons["tab.ideas"].tap()
        let idea = app.buttons["board.idea.probe-trip"]
        XCTAssertTrue(idea.waitForExistence(timeout: 10))
        idea.press(forDuration: 1.2)
        let promote = app.buttons["Turn into a goal"]
        XCTAssertTrue(promote.waitForExistence(timeout: 5))
        promote.tap()
        XCTAssertTrue(idea.waitForNonExistence(timeout: 10), "The idea leaves Ideas")
        app.buttons["tab.goals"].tap()
        let goal = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Plan a weekend trip")).firstMatch
        XCTAssertTrue(goal.waitForExistence(timeout: 10), "…and shows in Goals")
        save("features-4-idea-to-goal", app)

        // Projects: make one, start a chat in it, find the chat in the project.
        app.buttons["tab.sessions"].tap()
        let menu = app.buttons["chat.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let projects = app.buttons["menu.projects"]
        XCTAssertTrue(projects.waitForExistence(timeout: 5), "Projects is in the menu")
        projects.tap()
        XCTAssertTrue(app.descendants(matching: .any)["projects.screen"].waitForExistence(timeout: 10))
        let create = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["projects.new", "projects.empty.new"])).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let name = app.textFields["hermes-workspaces.create.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Garden")
        let summary = app.textFields["hermes-workspaces.create.summary"]
        summary.tap()
        summary.typeText("Plants and watering")
        let folder = app.textFields["hermes-workspaces.create.path"]
        folder.tap()
        folder.typeText(try XCTUnwrap(probe["project_dir"]))
        save("features-5-new-project", app)
        app.buttons["hermes-workspaces.create.submit"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "projects.card.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The new project is listed")
        XCTAssertTrue(app.staticTexts["Plants and watering"].waitForExistence(timeout: 5), "with its description")
        save("features-6-projects", app)
        card.tap()
        let newChat = app.buttons["project.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A chat opens in the project")
        composer.tap()
        composer.typeText("Hello from the Garden project")
        app.buttons["chat.send"].tap()
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Direct streaming fixture complete.", "Direct streaming fixture complete.")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 90), "The agent replies")
        swipeBackFromLeadingEdge(in: app)
        let chatRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "project.chat.")).firstMatch
        let found = chatRow.waitForExistence(timeout: 20) || {
            app.swipeDown()
            return chatRow.waitForExistence(timeout: 20)
        }()
        XCTAssertTrue(found, "The chat is filed under the project")
        save("features-7-project-chats", app)
    }

    /// The host's profile sets no terminal.cwd, so its agent works where Hermes was started.
    /// The Apps tab still shows the agent's files from there, not "Workspace unavailable".
    @MainActor
    func testAppsShowsTheAgentsFilesWithNoWorkingFolderSet() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes features")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "features", let fileName = probe["workspace_file"] else {
            throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode")
        }
        let app = makeApp()
        app.launchArguments = ["-loopdy.home.opens-chat", "YES"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 30), "The agent's chat opens")
        let appsTab = app.buttons["tab.apps"]
        XCTAssertTrue(appsTab.waitForExistence(timeout: 10))
        appsTab.tap()
        let file = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fileName)).firstMatch
        let shown = file.waitForExistence(timeout: 30)
        save("features-8-apps-files", app)
        XCTAssertTrue(shown, "The agent's file shows in Apps")
        XCTAssertFalse(app.staticTexts["Workspace unavailable"].exists)
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
