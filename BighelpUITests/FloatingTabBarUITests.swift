import XCTest

final class FloatingTabBarUITests: BighelpUITestCase {
    private let destinations = [
        (root: "chats", sidebar: "menu.chats"),
        (root: "agents", sidebar: "menu.agents"),
        (root: "scheduledTasks", sidebar: "menu.scheduled-tasks"),
        (root: "workspace", sidebar: "menu.hermes-tools"),
    ]

    @MainActor
    private func launch(version: String, appearance: String, accessibility: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
                               "-loopdy.appearance.interface-version", version,
                               "-loopdy.demo.appearance", appearance]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testFourDestinationsShareIconAndCaptionGeometryInBothAppearances() {
        for version in ["v3"] {
            for appearance in ["light", "dark"] {
                let app = launch(version: version, appearance: appearance)
                assertNativeNavigationGeometry(app)
                openRootDestination("chats", sidebarIdentifier: "menu.chats", in: app)
                assertNativeNavigationGeometry(app)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "navigation-\(version)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    @MainActor
    func testAccessibilityTextFitsUniformTargetsWithoutOverlapping() {
        let app = launch(version: "v3", appearance: "dark", accessibility: true)
        assertNativeNavigationGeometry(app)
    }

    @MainActor
    func testNewChatOpensChatWithoutLeavingRootNavigationVisible() {
        let app = launch(version: "v3", appearance: "light")
        app.buttons["root.new-chat"].tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        // The chat draws its own bar under the message box; the root's doesn't stay behind.
        let bars = app.otherElements.matching(identifier: "primary-navigation")
        XCTAssertEqual(bars.count, 1)
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertLessThanOrEqual(composer.frame.maxY, bars.firstMatch.frame.minY + 1)
    }

    /// On Chats, New chat sits centered above the tabs instead of squeezing
    /// them; the tab row is as wide as on every other tab.
    @MainActor
    func testChatsNewChatSitsCenteredAboveFullWidthTabs() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            let newChat = app.buttons["root.new-chat"]
            let chats = app.buttons["tab.sessions"], apps = app.buttons["tab.apps"]
            XCTAssertTrue(newChat.waitForExistence(timeout: 20))
            XCTAssertTrue(newChat.isHittable)
            XCTAssertLessThanOrEqual(newChat.frame.maxY, chats.frame.minY, "New chat sits above the tabs")
            XCTAssertEqual(newChat.frame.midX, app.frame.midX, accuracy: 1, "New chat is centered")
            let chatsRowWidth = apps.frame.maxX - chats.frame.minX
            if let folder = ProcessInfo.processInfo.environment["BIGHELP_TABBAR_EVIDENCE"] {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try app.screenshot().pngRepresentation
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("chats-\(appearance).png"))
            }

            app.buttons["tab.feed"].tap()
            XCTAssertTrue(newChat.waitForNonExistence(timeout: 5))
            XCTAssertEqual(apps.frame.maxX - chats.frame.minX, chatsRowWidth, accuracy: 1,
                           "The tab row keeps its width on Chats")
            app.terminate()
        }
    }

    /// Native rows behind a transparent modal must not receive drawer taps.
    @MainActor
    func testWorkspaceDrawerOwnsFirstTapAndRestoresRootAfterDismissal() {
        let app = launch(version: "v3", appearance: "light")
        openRootDestination("workspace", sidebarIdentifier: "menu.hermes-tools", in: app)
        let rootMenu = app.buttons["home.drawer.open"]
        let underlyingActivity = app.buttons["workspace.open.activity"]
        XCTAssertTrue(underlyingActivity.waitForExistence(timeout: 5))
        rootMenu.tap()
        let close = app.buttons["menu.done"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        // A transparent cover retains underlying AX elements, but not hit targets.
        XCTAssertFalse(underlyingActivity.isHittable, "The modal must block underlying native rows.")
        close.tap()
        XCTAssertTrue(underlyingActivity.waitForExistence(timeout: 5))
        XCTAssertTrue(underlyingActivity.isHittable)
        underlyingActivity.tap()
        XCTAssertTrue(app.collectionViews["dashboard.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "workspace-drawer-activity-first-tap"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Catches root tab content failing to inherit the custom navigation's reserved space.
    @MainActor
    func testSettingsFinalRowRemainsReachableWithoutRootNavigation() {
        let app = launch(version: "v3", appearance: "light")
        openSettings(in: app)
        let form = app.collectionViews["settings.screen"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<6 { form.swipeUp() }
        // With Nerd Mode on, "Display & data" is the final Advanced row.
        let lastRow = app.buttons["settings.advanced"]
        XCTAssertTrue(lastRow.exists)
        // Settings is a root tab; the tab bar must never cover its last row.
        XCTAssertTrue(lastRow.isHittable)
        let navigation = app.otherElements["primary-navigation"]
        if navigation.exists && navigation.isHittable {
            XCTAssertFalse(navigation.frame.intersects(lastRow.frame))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "profile-final-row-scroll-clearance"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, app.frame.maxY,
                                 "The whole final Settings row must remain inside the screen.")
        XCTAssertTrue(lastRow.isHittable)
    }

    @MainActor
    func testAllRootFinalItemsClearGlassNavigation() {
        let app = launch(version: "v3", appearance: "light")
        app.buttons["home.drawer.open"].tap()
        let chats = app.buttons["menu.chats"]
        let agents = app.buttons["menu.agents"]
        let tasks = app.buttons["menu.scheduled-tasks"]
        for destination in [chats, agents, tasks] {
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            XCTAssertTrue(destination.isHittable)
            XCTAssertGreaterThanOrEqual(destination.frame.height, 44)
        }
        XCTAssertLessThan(chats.frame.maxY, agents.frame.midY,
                          "Conversation rooms stay above the Agents destination.")
        agents.tap()
        XCTAssertTrue(app.descendants(matching: .any)["agents.screen"].firstMatch
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testAllRootFinalItemsClearExpandedAccessibilityNavigation() {
        assertRootScrollClearance(accessibility: true, landscape: false)
    }

    @MainActor
    func testAllRootFinalItemsClearGlassNavigationInLandscape() {
        assertRootScrollClearance(accessibility: false, landscape: true)
    }

    @MainActor
    private func assertRootScrollClearance(accessibility: Bool, landscape: Bool) {
        let app = launch(version: "v3", appearance: "light", accessibility: accessibility)
        if landscape {
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.frame.width > app.frame.height
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        }
        defer { XCUIDevice.shared.orientation = .portrait }

        let routes = [
            (name: "agents", root: "agents", sidebar: "menu.agents", screen: "agents.screen"),
            (name: "chats", root: "chats", sidebar: "menu.chats", screen: "sessions.screen"),
            (name: "scheduled tasks", root: "scheduledTasks", sidebar: "menu.scheduled-tasks", screen: "scheduled-tasks.screen"),
            (name: "workspace", root: "workspace", sidebar: "menu.hermes-tools", screen: "workspace.hub"),
            (name: "activity", root: "activity", sidebar: "", screen: "dashboard.screen"),
        ]
        for route in routes {
            // Activity is one of the host's tools: Hermes Tools in the ☰ menu.
            if route.sidebar.isEmpty { openActivity(in: app) }
            else { openRootDestination(route.root, sidebarIdentifier: route.sidebar, in: app) }
            let screen = app.descendants(matching: .any)[route.screen].firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 5), route.name)
            XCTAssertGreaterThan(screen.frame.height, 0, route.name)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "native-navigation-\(route.name)-\(accessibility ? "accessibility" : "standard")-\(landscape ? "landscape" : "portrait")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        openSettings(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch
            .waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertNativeNavigationGeometry(_ app: XCUIApplication,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let usesPersistentSidebar = app.buttons["root.destination.chats"].exists
        if !usesPersistentSidebar {
            app.buttons["home.drawer.open"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["navigation.menu"].firstMatch
                .waitForExistence(timeout: 5), file: file, line: line)
        }
        let buttons = destinations.map {
            app.buttons[usesPersistentSidebar ? "root.destination.\($0.root)" : $0.sidebar].firstMatch
        }
        // With very large text the menu scrolls; every destination must still be reachable.
        let menu = app.descendants(matching: .any)["navigation.menu"].firstMatch
        var previous: XCUIElement?
        for (index, button) in buttons.enumerated() {
            for _ in 0..<6 where !usesPersistentSidebar && !(button.exists && button.isHittable) { menu.swipeUp() }
            XCTAssertTrue(button.exists, destinations[index].root, file: file, line: line)
            XCTAssertTrue(button.isHittable, destinations[index].root, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, file: file, line: line)
            if let previous, previous.exists, previous.isHittable {
                XCTAssertGreaterThan(button.frame.midY, previous.frame.midY, file: file, line: line)
                XCTAssertFalse(button.frame.intersects(previous.frame), file: file, line: line)
            }
            previous = button
        }
        if !usesPersistentSidebar {
            app.buttons["menu.done"].tap()
        }
    }
}
