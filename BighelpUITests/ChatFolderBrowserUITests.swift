import XCTest

/// A chat's Files on the demo's folders (#944): ••• › Files opens the chat's working folder as a
/// tree, a folder opens in place, a file opens to read, search finds names in opened folders, and
/// the path field shows another folder. Set BIGHELP_TOOL_FOLDERS_EVIDENCE (TEST_RUNNER_…) to a
/// folder to save the screenshots.
final class ChatFolderBrowserUITests: BighelpUITestCase {
    @MainActor
    func testFilesShowsTheWorkingFolderAndAnyOtherFolder() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.tables["chat.timeline"].waitForExistence(timeout: 10))
            chatMenuItem("chat.files", in: app).tap()

            // The working folder, folders first.
            let path = app.textFields["chat.files.path"]
            XCTAssertTrue(path.waitForExistence(timeout: 10))
            XCTAssertEqual(path.value as? String, "/Users/demo/Projects/weather-app")
            let src = app.buttons["chat.files.row.src"]
            XCTAssertTrue(src.waitForExistence(timeout: 5))
            XCTAssertEqual(src.value as? String, "Collapsed")
            XCTAssertLessThan(src.frame.minY, app.buttons["chat.files.row.README.md"].frame.minY)
            XCTAssertFalse(app.buttons["chat.files.working-folder"].isEnabled, "Already there")
            // Names that start with a dot wait behind one line.
            XCTAssertFalse(app.buttons["chat.files.row..gitignore"].exists)
            let hidden = app.buttons["chat.files.hidden"]
            XCTAssertEqual(hidden.label, "Show 2 hidden items")
            hidden.tap()
            XCTAssertTrue(app.buttons["chat.files.row..gitignore"].waitForExistence(timeout: 5))
            hidden.tap()
            XCTAssertTrue(app.buttons["chat.files.row..gitignore"].waitForNonExistence(timeout: 5))

            // A folder opens in place.
            src.tap()
            XCTAssertEqual(src.value as? String, "Expanded")
            let forecast = app.buttons["chat.files.row.forecast.ts"]
            XCTAssertTrue(forecast.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(forecast.frame.minX, src.frame.minX - 1)
            save("files-tree-\(appearance)", app)

            // A text file opens as it is; Markdown opens rendered.
            forecast.tap()
            let text = app.descendants(matching: .any)["chat.files.text"].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "export function forecast"))
                .firstMatch.exists)
            save("files-text-\(appearance)", app)
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons["chat.files.row.README.md"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["markdown-file.rendered"].firstMatch
                .waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()

            // Search finds names in the folders opened so far, and says where.
            XCTAssertTrue(path.waitForExistence(timeout: 5), "Back on the tree")
            let search = app.descendants(matching: .any).matching(identifier: "chat.files.search").firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            app.typeText("units\n")
            XCTAssertTrue(app.buttons["chat.files.row.units.ts"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["chat.files.row.README.md"].exists)
            XCTAssertTrue(app.buttons["chat.files.row.units.ts"].label.contains("units.ts"))

            // The path field shows another folder; the house goes back.
            path.tap()
            path.press(forDuration: 1.2)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            path.typeText("~/Projects\n")
            XCTAssertTrue(app.buttons["chat.files.row.travel"].waitForExistence(timeout: 5))
            XCTAssertEqual(path.value as? String, "/Users/demo/Projects")
            save("files-other-folder-\(appearance)", app)
            let home = app.buttons["chat.files.working-folder"]
            XCTAssertTrue(home.isEnabled)
            home.tap()
            XCTAssertTrue(app.buttons["chat.files.row.src"].waitForExistence(timeout: 5))
            XCTAssertEqual(path.value as? String, "/Users/demo/Projects/weather-app")

            app.buttons["chat.files.done"].tap()
            XCTAssertTrue(path.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    /// The same page on a real Hermes host (a probe file naming an open host, and
    /// BIGHELP_BOT_CHAT_AGENT, an agent of its own): Hermes' own folder routes answer for the
    /// agent's Bot Chat. It sends no message. Skipped without the probe.
    @MainActor
    func testFilesOnARealHost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let probePath = environment["BIGHELP_SIGNIN_PROBE"], let agent = environment["BIGHELP_BOT_CHAT_AGENT"] else {
            throw XCTSkip("Needs BIGHELP_SIGNIN_PROBE and BIGHELP_BOT_CHAT_AGENT")
        }
        let probe = try JSONDecoder().decode([String: String].self,
                                             from: Data(contentsOf: URL(fileURLWithPath: probePath)))
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address"]))
        openHostBot(agent, in: app)
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 45), "Its Bot Chat opens")
        chatMenuItem("chat.files", in: app).tap()

        // The working folder: a full path, with what Hermes lists in it.
        let path = app.textFields["chat.files.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 10))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.files.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "Hermes lists the working folder")
        let working = try XCTUnwrap(path.value as? String)
        XCTAssertTrue(working.hasPrefix("/"), working)
        XCTAssertFalse(app.buttons["chat.files.working-folder"].isEnabled)
        save("host-files-working-folder", app)

        // The folder above.
        app.buttons["chat.files.up"].tap()
        let above = (working as NSString).deletingLastPathComponent
        let moved = expectation(for: NSPredicate(format: "value == %@", above), evaluatedWith: path)
        wait(for: [moved], timeout: 15)
        XCTAssertTrue(app.buttons["chat.files.row.\((working as NSString).lastPathComponent)"]
            .waitForExistence(timeout: 10), "The working folder is in the folder above it")

        // A typed "~" path opens home under its real name (the working folder itself, on some hosts).
        path.tap()
        path.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        path.typeText("~\n")
        let home = expectation(for: NSPredicate(format: "value BEGINSWITH %@ AND value != %@", "/", above),
                               evaluatedWith: path)
        wait(for: [home], timeout: 15)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))

        // Back to the working folder, then a path that isn't there says so.
        if app.buttons["chat.files.working-folder"].isEnabled { app.buttons["chat.files.working-folder"].tap() }
        let back = expectation(for: NSPredicate(format: "value == %@", working), evaluatedWith: path)
        wait(for: [back], timeout: 15)
        path.tap()
        path.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        path.typeText("/bighelp-no-such-folder\n")
        XCTAssertTrue(app.staticTexts["There's no folder at that path."].waitForExistence(timeout: 10))
        save("host-files-missing-folder", app)
        app.buttons["chat.files.done"].tap()
        app.terminate()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_TOOL_FOLDERS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// Opens a real host's bot from Bots (`simple-bots.bot.<id>`), through Search when the list hasn't
    /// built its row; the tap opens its Bot Chat.
    @MainActor
    private func openHostBot(_ agent: String, in app: XCUIApplication) {
        showBots(in: app)
        var row = app.buttons["simple-bots.bot.\(agent)"].firstMatch
        // A long list builds only the rows on screen.
        if !row.waitForExistence(timeout: 20) {
            let search = app.buttons["simple-bots.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            let field = app.descendants(matching: .any)["simple-bots.search.field"].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10))
            field.tap()
            field.typeText(agent)
            row = app.buttons["simple-bots.search.bot.\(agent)"].firstMatch
        }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(agent) on Bots")
        row.tap()
    }
}
