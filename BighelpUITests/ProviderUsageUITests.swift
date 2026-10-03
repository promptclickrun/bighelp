import XCTest

/// Provider Usage on demo data: the ways in (chat ⋯, ☰), closing it, and
/// hiding a provider in Settings. The context window's way in is in
/// ChatContextWindowUITests.
/// BIGHELP_USAGE_EVIDENCE (TEST_RUNNER_…) saves screenshots.
final class ProviderUsageUITests: BighelpUITestCase {
    @MainActor
    func testOpensFromChatMenuAndMainMenu() throws {
        let app = launchChat(appearance: "light")
        app.buttons["chat.options"].tap()
        tap(app.buttons["chat.provider-usage"])
        let overlay = expectOverlay(app)
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.claude"].exists, "Claude card")
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.gemini"].exists, "Status cards render")
        save("usage-1-from-chat-menu", app)
        app.buttons["provider-usage.close"].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3), "X closes it")

        // ⋯ › Context window › usage is covered by ChatContextWindowUITests.

        openMainMenu(app)
        let menuRow = app.buttons["menu.usage"]
        XCTAssertTrue(menuRow.waitForExistence(timeout: 5))
        for _ in 0..<4 where !menuRow.isHittable { app.swipeUp() }
        menuRow.tap()
        _ = expectOverlay(app)
        // Tapping outside the panel closes it too.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.5)).tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 3), "Tapping outside closes it")
    }

    @MainActor
    func testDarkAppearanceAndHidingAProviderInSettings() throws {
        let app = launchChat(appearance: "dark")
        app.buttons["chat.options"].tap()
        tap(app.buttons["chat.provider-usage"])
        _ = expectOverlay(app)
        save("usage-3-dark", app)
        app.buttons["provider-usage.close"].tap()

        openMainMenu(app)
        // Settings sits below the fold in the menu's list; scroll to it.
        let settings = app.buttons["menu.settings"]
        _ = app.buttons["menu.new-chat"].waitForExistence(timeout: 5)
        for _ in 0..<6 where !(settings.exists && settings.isHittable) { app.swipeUp() }
        XCTAssertTrue(settings.exists)
        settings.tap()
        let row = settingsRow("settings.provider-usage", in: app)
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        let openRouter = app.switches["settings.provider-usage.openrouter"]
        XCTAssertTrue(openRouter.waitForExistence(timeout: 10), "Providers are listed")
        // A saved choice from an earlier run: start from everything shown.
        let showAll = app.buttons["settings.provider-usage.show-all"]
        if showAll.exists { showAll.tap() }
        XCTAssertEqual(openRouter.value as? String, "1", "Shown until turned off")
        let control = openRouter.switches.firstMatch.exists ? openRouter.switches.firstMatch : openRouter
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let off = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: openRouter)
        wait(for: [off], timeout: 3)
        save("usage-4-settings", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Reopen from ☰, wherever Settings left us.
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let usage = app.buttons["menu.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        for _ in 0..<4 where !usage.isHittable { app.swipeUp() }
        usage.tap()
        _ = expectOverlay(app)
        XCTAssertFalse(app.descendants(matching: .any)["provider-usage.openrouter"].exists, "Hidden provider stays hidden")
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.claude"].exists)
        save("usage-5-openrouter-hidden", app)
    }

    @MainActor
    private func launchChat(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 10))
        return app
    }

    /// ☰ lives on the chat list; a chat opened from the list shows Back instead.
    @MainActor
    private func openMainMenu(_ app: XCUIApplication) {
        let back = app.buttons["chat.back"]
        if back.exists { back.tap() }
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "☰ menu")
        menu.tap()
    }

    @MainActor
    private func expectOverlay(_ app: XCUIApplication) -> XCUIElement {
        let overlay = app.descendants(matching: .any)["provider-usage"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 8), "Provider Usage opens")
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.codex"].waitForExistence(timeout: 8), "Cards load")
        sleep(1)
        return overlay
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_USAGE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
