import XCTest

/// The computer in use's own Sessions page, pushed from Chats › This computer: project folders fold,
/// and chats other apps (Codex, Claude Code) made on the computer show and open.
/// Set BIGHELP_PARITY_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class SessionsParityUITests: BighelpUITestCase {
    @MainActor
    func testProjectFolderFoldsItsChats() throws {
        let app = launch(extra: ["-loopdy.sessions.organizeByProjects", "YES"])
        openThisComputerSessions(in: app)

        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sessions.section-toggle.'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 8), "Group by Project shows project folders")
        // The chat right under the folder is the folder's own.
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let own = try XCTUnwrap(rows.allElementsBoundByIndex
            .filter { $0.frame.minY > folder.frame.minY }.min { $0.frame.minY < $1.frame.minY })
        let ownID = own.identifier
        let before = rows.allElementsBoundByIndex.map(\.identifier)
        save("folders-open", app)
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Collapsed")
        sleep(1)
        save("folder-folded", app)
        let after = rows.allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(after.contains(ownID),
                       "Its chats fold away with it: folder \(folder.identifier), \(ownID), before \(before), after \(after)")
        folder.tap()
        XCTAssertEqual(folder.value as? String, "Expanded")
        XCTAssertTrue(app.descendants(matching: .any)[ownID].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCodexAndClaudeCodeChatsShowAndOpen() throws {
        let app = launch()
        openThisComputerSessions(in: app)

        let codex = app.buttons["sessions.other-app.Polish the Mac menus"]
        for _ in 0..<6 where !codex.exists { app.swipeUp() }
        XCTAssertTrue(codex.waitForExistence(timeout: 5), "Codex chats on the computer are listed")
        XCTAssertTrue(codex.label.contains("Codex"), codex.label)
        save("other-apps", app)
        codex.tap()
        let open = app.buttons["sessions.other-apps.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "A tap shows how it starts first")
        save("other-app-preview", app)
        open.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 8), "Open opens it as a chat")
    }

    // MARK: Helpers

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "chats"] + extra
        app.launch()
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PARITY_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

extension BighelpUITestCase {
    /// Chats › This computer: the computer in use's own Sessions page (projects, filters, other apps'
    /// chats), pushed from the More section at the end of the Chats list.
    @MainActor
    func openThisComputerSessions(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        showChats(in: app)
        let list = app.descendants(matching: .any)["chats.inbox"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 20), "Chats shows", file: file, line: line)
        let row = app.buttons["chats.more.this-computer"].firstMatch
        for _ in 0..<20 where !(row.exists && row.isHittable) { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(row.exists && row.isHittable, "This computer is at the end of Chats", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sessions.screen"].firstMatch.waitForExistence(timeout: 10),
                      "This computer opens its Sessions page", file: file, line: line)
    }
}
