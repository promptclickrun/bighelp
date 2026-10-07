import XCTest

extension BighelpUITestCase {
    @MainActor
    func openRootDestination(_ destination: String, sidebarIdentifier: String,
                             in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        if sidebarIdentifier == "menu.hermes-tools" {
            // Hermes tools moved from ☰ into Settings (Nerd Mode).
            openSettings(in: app, file: file, line: line)
            let tools = settingsRow("settings.hermes-tools", in: app, file: file, line: line)
            guard tools.exists else { return }
            tools.tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.hub"].firstMatch.waitForExistence(timeout: 5),
                          "Settings › Hermes tools must open the tools list.", file: file, line: line)
            return
        }
        // iPad and iPhone share ☰; there's no always-open sidebar.
        openSidebarDestination(sidebarIdentifier, in: app, file: file, line: line)
    }

    @MainActor
    func openAgents(in app: XCUIApplication,
                    file: StaticString = #filePath, line: UInt = #line) {
        openRootTab("tab.agents", in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch.waitForExistence(timeout: 5),
                      "Agents must remain reachable through the current native navigation.",
                      file: file, line: line)
    }

    @MainActor
    func openSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Already open: Settings is a sheet over the screen it was opened from.
        if app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 1) { return }
        // Settings sits in ☰ on iPhone and iPad.
        openRootTab("tab.profile", in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 5),
                      "The Settings destination must open through ☰.", file: file, line: line)
    }

    /// Settings is a sheet: Done closes it and shows the screen under it again.
    @MainActor
    func closeSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["settings.done"].firstMatch
        guard done.waitForExistence(timeout: 3) else { return }
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done closes Settings", file: file, line: line)
    }

    /// Root lists keep search under the large title; it appears on pull-down.
    @MainActor
    @discardableResult
    func revealSearchField(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        if field.waitForExistence(timeout: 2) { return true }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        // Tap the status bar (iOS scroll-to-top), then flick and pull down past
        // the top edge, which is what reveals the search field.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.005)).tap()
        if field.waitForExistence(timeout: 1) { return true }
        for _ in 0..<12 {
            list.swipeDown()
            if field.waitForExistence(timeout: 0.5) { return true }
        }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
        return field.waitForExistence(timeout: 2)
    }

    @MainActor
    func openActivity(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openHermesTool("activity", in: app, file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.screen"].firstMatch.waitForExistence(timeout: 5),
                      "Activity must open from Settings › Hermes tools.", file: file, line: line)
    }

    @MainActor
    func openSkillsAndTools(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openHermesTool("skills", in: app, file: file, line: line)
    }

    /// Host tools live in Settings › Hermes tools (Nerd Mode).
    @MainActor
    func openHermesTool(_ destination: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        openSettings(in: app, file: file, line: line)
        let tools = settingsRow("settings.hermes-tools", in: app, file: file, line: line)
        guard tools.exists else { return }
        tools.tap()
        let row = app.buttons["workspace.open.\(destination)"].firstMatch
        // Let Hermes Tools finish opening before scrolling, or the first rows scroll away.
        _ = app.descendants(matching: .any)["workspace.hub"].firstMatch.waitForExistence(timeout: 5)
        _ = row.waitForExistence(timeout: 2)
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Hermes Tools must list \(destination).", file: file, line: line)
        guard row.exists else { return }
        row.tap()
    }

    @MainActor
    func openChatWorkspaceMenu(in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        // A chat's ☰ is the one menu, top left in its header.
        let menu = app.buttons["home.drawer.open"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "The chat header must expose ☰.", file: file, line: line)
        guard menu.exists else { return }
        menu.tap()
    }

    @MainActor
    func openSidebarDestination(_ identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let destinations = app.buttons.matching(identifier: identifier)
        // A persistent iPad sidebar already exposes the same destination.
        if !destinations.allElementsBoundByIndex.contains(where: \.isHittable) {
            let rootMenu = app.buttons["home.drawer.open"].firstMatch
            let chatOptions = app.buttons["chat.options"].firstMatch
            let nestedMenu = app.buttons["workspace.menu"].firstMatch
            if !(rootMenu.exists && rootMenu.isHittable) && chatOptions.exists && chatOptions.isHittable {
                openChatWorkspaceMenu(in: app, file: file, line: line)
            } else {
                let menu = rootMenu.exists && rootMenu.isHittable ? rootMenu : nestedMenu
                XCTAssertTrue(menu.waitForExistence(timeout: 8), "The visible screen must expose its sidebar.",
                              file: file, line: line)
                guard menu.exists else { return }
                menu.tap()
            }
        }
        let nativeMenu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        for _ in 0..<8 where !destinations.allElementsBoundByIndex.contains(where: \.isHittable) {
            if nativeMenu.exists { nativeMenu.swipeUp() }
        }
        let destination = destinations.allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(destination, "Sidebar destination must be reachable: \(identifier)",
                        file: file, line: line)
        guard let destination else { return }
        destination.tap()
    }
}
