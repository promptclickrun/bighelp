import XCTest

extension BighelpUITestCase {
    @MainActor
    func openRootDestination(_ destination: String, sidebarIdentifier: String,
                             in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
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

    /// Settings › Connections, then one of its rows: Device access (`settings.connections.device-access`)
    /// or the credential vault (`settings.connections.vault`).
    @MainActor
    func openConnectionsRow(_ identifier: String, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        openSettings(in: app, file: file, line: line)
        settingsRow("settings.apps", in: app, file: file, line: line).tap()
        let row = app.buttons[identifier].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Connections lists \(identifier)", file: file, line: line)
        row.tap()
    }

    /// Settings › Connections › Device access.
    @MainActor
    func openDeviceAccessSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openConnectionsRow("settings.connections.device-access", in: app, file: file, line: line)
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

    /// A computer's tool page, from the page it lives on (#976): skills, plugins, mcp, toolsets and
    /// messaging in Settings › Apps & skills; logs and webhooks on the computer's own page;
    /// sessionMaintenance (Clean up chats) in Settings › Chat. The Advanced rows need Advanced options on.
    @MainActor
    func openHostPage(_ page: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        openSettings(in: app, file: file, line: line)
        let row: XCUIElement
        switch page {
        case "logs", "webhooks":
            let computer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "hosts.host.")).firstMatch
            for _ in 0..<8 where !(computer.exists && computer.isHittable) { app.swipeUp() }
            XCTAssertTrue(computer.exists, "Settings lists the computer.", file: file, line: line)
            guard computer.exists else { return }
            computer.tap()
            row = app.buttons["system.\(page)"].firstMatch
        case "sessionMaintenance":
            settingsRow("settings.menu.chat", in: app, file: file, line: line).tap()
            row = app.buttons["settings.chat.clean-up-chats"].firstMatch
        default:
            settingsRow("settings.apps", in: app, file: file, line: line).tap()
            row = app.buttons["marketplace.\(page)"].firstMatch
        }
        _ = row.waitForExistence(timeout: 5)
        for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.exists, "\(page) must be reachable from Settings.", file: file, line: line)
        guard row.exists else { return }
        row.tap()
    }

    /// Leaves Settings from any page in it: Back until Done shows, then Done.
    @MainActor
    func leaveSettings(in app: XCUIApplication) {
        let done = app.buttons["settings.done"].firstMatch
        for _ in 0..<6 where !(done.exists && done.isHittable) {
            // The sheet's own Back: the screen behind it has a navigation bar too.
            let back = app.buttons["BackButton"].firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        if done.exists, done.isHittable { done.tap() }
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
