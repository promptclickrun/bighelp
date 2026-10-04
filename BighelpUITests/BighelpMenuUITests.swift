import XCTest

/// One menu (☰) with hosts, chats and everywhere else; the bighelp logo switches
/// hosts on touch and hold; Settings holds this app's settings and, in Nerd Mode,
/// the host's tools. Set BIGHELP_MENU_EVIDENCE (TEST_RUNNER_BIGHELP_MENU_EVIDENCE) to
/// save screenshots.
final class BighelpMenuUITests: BighelpUITestCase {
    @MainActor
    func testOneMenuHostsChatsAndSettings() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-use-multi-host-fixtures",
                               "-loopdy.demo.appearance", "dark"]
        app.launch()
        openSettings(in: app)
        XCTAssertFalse(app.buttons["quick-workspace.menu"].exists, "The grid button is gone.")
        save("01-settings", app)

        // ☰: the host on top as one row, then the places you go, then recent chats.
        tap(app.buttons["home.drawer.open"])
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let hostSwitcher = app.buttons["menu.hosts"].firstMatch
        XCTAssertTrue(hostSwitcher.waitForExistence(timeout: 3), "One row switches hosts.")
        XCTAssertTrue(app.buttons["menu.new-chat"].waitForExistence(timeout: 3))
        let newChat = app.buttons["menu.new-chat"]
        XCTAssertGreaterThan(newChat.frame.minX, hostSwitcher.frame.maxX, "Its own button, right of the host")
        XCTAssertLessThan(abs(newChat.frame.midY - hostSwitcher.frame.midY), 12, "On the host's row")
        save("02-menu", app)
        // Everything on the first screen is reachable without scrolling.
        for id in ["menu.new-chat", "menu.agents", "menu.projects", "menu.scheduled-tasks", "menu.settings", "menu.chats"] {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) shows without scrolling")
        }
        XCTAssertLessThan(app.buttons["menu.agents"].frame.minY, app.buttons["menu.settings"].frame.minY)
        XCTAssertLessThan(app.buttons["menu.new-chat"].frame.minY, app.buttons["menu.agents"].frame.minY,
                          "New chat first, then Agents")
        XCTAssertFalse(app.buttons["menu.new-group"].exists, "Group chats start from New chat's own picker")
        XCTAssertFalse(app.buttons["menu.all-agents"].exists, "One host: Agents is this host's")
        XCTAssertLessThan(app.buttons["menu.settings"].frame.maxY, app.buttons["menu.chats"].frame.minY,
                          "Recent chats come after the places you go")
        hostSwitcher.tap()
        let hosts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "menu.host.")).allElementsBoundByIndex
        XCTAssertFalse(hosts.isEmpty, "The switcher lists hosts.")
        save("02b-host-switcher", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        XCTAssertFalse(app.buttons["menu.hermes-tools"].exists, "Hermes tools live in Settings, not the menu.")
        tap(app.buttons["menu.settings"])

        // Settings › Hermes tools keeps the host's tools; this app's own settings aren't in it.
        openHermesTool("activity", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["dashboard.screen"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["workspace.hub"].firstMatch.waitForExistence(timeout: 5))
        for moved in ["appearance", "permissions", "watch", "contact", "tabBar", "caching", "instances", "security"] {
            XCTAssertFalse(app.buttons["workspace.open.\(moved)"].exists, moved)
        }
        save("03-hermes-tools", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Touch and hold the logo to switch hosts.
        let logo = app.buttons["brand.host-switcher"].firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        logo.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["brand.host.add"].waitForExistence(timeout: 5))
        save("04-logo-host-switcher", app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()

        // Settings: help, Apple Watch and hosts live here.
        openSettings(in: app)
        let help = app.buttons["settings.menu.help"].firstMatch
        let watch = app.buttons["settings.menu.watch"].firstMatch
        for _ in 0..<8 where !(help.exists && help.isHittable && watch.exists && watch.isHittable) { app.swipeUp() }
        XCTAssertTrue(help.exists, "Settings has Help & feedback.")
        XCTAssertTrue(watch.exists, "Settings has Apple Watch.")
        save("05-settings-help", app)
        tap(help)
        XCTAssertTrue(app.staticTexts["Version"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing \(element)")
        guard element.exists else { return }
        element.tap()
        sleep(1)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MENU_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
