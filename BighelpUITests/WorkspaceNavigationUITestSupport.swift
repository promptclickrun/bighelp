import XCTest

/// The one home's doors: three tabs (Bots or Chats, Today, Work) with New chat beside the bar,
/// Settings behind the person's circle, and every chat, bot page and door a pushed page with Back.
extension BighelpUITestCase {
    // MARK: The one home

    /// Leaves whatever covers the home (Settings, a chat, a bot page, a pushed page) until the bar shows.
    @MainActor
    func returnToHome(in app: XCUIApplication, timeout: TimeInterval = 20,
                      file: StaticString = #filePath, line: UInt = #line) {
        let newChat = app.buttons["home.new-chat"].firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        while !(newChat.exists && newChat.isHittable), Date.now < deadline {
            if !stepBackTowardHome(in: app) { _ = newChat.waitForExistence(timeout: 1) }
        }
        XCTAssertTrue(newChat.exists && newChat.isHittable, "The home's bar must show", file: file, line: line)
    }

    /// One step back toward the home: closes Settings or taps the Back of what is on top. False when
    /// nothing could be tapped.
    @MainActor
    private func stepBackTowardHome(in app: XCUIApplication) -> Bool {
        if app.buttons["settings.done"].firstMatch.exists {
            leaveSettings(in: app)
            return true
        }
        for identifier in ["chat.back", "simple-bots.profile.back", "today.board-page.back"] {
            let back = app.buttons[identifier].firstMatch
            if back.exists, back.isHittable { back.tap(); return true }
        }
        // A door's page or Sessions has the system Back, top left.
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable, back.frame.minX < 60 { back.tap(); return true }
        return false
    }

    /// Opens one of the home's three tabs, "conversations", "today" or "work" (`home.tab.<tab>`).
    @MainActor
    func openHomeTab(_ tab: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["home.tab.\(tab)"].firstMatch
        if !(button.exists && button.isHittable) { returnToHome(in: app, timeout: timeout, file: file, line: line) }
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable, "Missing home.tab.\(tab)",
                      file: file, line: line)
        guard button.exists else { return }
        button.tap()
    }

    /// The first tab on its Bots view (`simple-bots.home`).
    @MainActor
    func showBots(in app: XCUIApplication, timeout: TimeInterval = 20,
                  file: StaticString = #filePath, line: UInt = #line) {
        showConversations("bots", root: "simple-bots.home", in: app, timeout: timeout, file: file, line: line)
    }

    /// The first tab on its Chats view (`chats.inbox`).
    @MainActor
    func showChats(in app: XCUIApplication, timeout: TimeInterval = 20,
                   file: StaticString = #filePath, line: UInt = #line) {
        showConversations("chats", root: "chats.inbox", in: app, timeout: timeout, file: file, line: line)
    }

    @MainActor
    private func showConversations(_ view: String, root: String, in app: XCUIApplication, timeout: TimeInterval,
                                   file: StaticString, line: UInt) {
        openHomeTab("conversations", in: app, timeout: timeout, file: file, line: line)
        let screen = app.descendants(matching: .any)[root].firstMatch
        if !screen.waitForExistence(timeout: 2) {
            let toggle = app.buttons["home.switch.\(view)"].firstMatch
            if toggle.waitForExistence(timeout: 5) { toggle.tap() }
        }
        XCTAssertTrue(screen.waitForExistence(timeout: timeout), "The first tab shows \(view)", file: file, line: line)
    }

    /// Today's Feed, Ideas and Goals panel on one board: "feed", "ideas" or "goals".
    @MainActor
    func openTodayPanel(_ kind: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                        file: StaticString = #filePath, line: UInt = #line) {
        openHomeTab("today", in: app, timeout: timeout, file: file, line: line)
        let picker = app.descendants(matching: .any)["today.boards.kind"].firstMatch
        let home = app.descendants(matching: .any)["today.home"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: timeout), "Today has its boards panel", file: file, line: line)
        for _ in 0..<4 where !picker.isHittable { home.swipeUp() }
        let titles = ["feed": "Feed", "ideas": "Ideas", "goals": "Goals"]
        let segment = picker.buttons[titles[kind] ?? kind].firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "The panel has \(kind)", file: file, line: line)
        if segment.exists, !segment.isSelected { segment.tap() }
    }

    /// Today › the panel's board ("feed", "ideas" or "goals") › See all: the whole board (`today.board-page`).
    @MainActor
    func openTodayBoard(_ kind: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                        file: StaticString = #filePath, line: UInt = #line) {
        openTodayPanel(kind, in: app, timeout: timeout, file: file, line: line)
        // See all shows once the board has something on it.
        let seeAll = app.buttons["today.boards.see-all"].firstMatch
        let home = app.descendants(matching: .any)["today.home"].firstMatch
        _ = seeAll.waitForExistence(timeout: timeout)
        for _ in 0..<4 where seeAll.exists && !seeAll.isHittable { home.swipeUp() }
        XCTAssertTrue(seeAll.exists && seeAll.isHittable, "\(kind) has See all", file: file, line: line)
        guard seeAll.exists else { return }
        seeAll.tap()
        XCTAssertTrue(app.descendants(matching: .any)["today.board-page"].firstMatch.waitForExistence(timeout: 10),
                      "See all opens the board", file: file, line: line)
    }

    /// Work › one of its doors: "projects", "tasks" (Kanban), "workflows" or "schedules".
    @MainActor
    func openWorkDoor(_ door: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                      file: StaticString = #filePath, line: UInt = #line) {
        openHomeTab("work", in: app, timeout: timeout, file: file, line: line)
        let screen = app.descendants(matching: .any)["work.screen"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: timeout), "Work opens", file: file, line: line)
        let button = app.buttons["work.door.\(door)"].firstMatch
        for _ in 0..<6 where !(button.exists && button.isHittable) { screen.swipeUp() }
        XCTAssertTrue(button.exists && button.isHittable, "Work has the \(door) door", file: file, line: line)
        guard button.exists else { return }
        button.tap()
    }

    /// The bar's New chat, then `new-chat.bot.<botID>`: a new chat with that bot in its To row.
    @MainActor
    func startNewChat(with botID: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        returnToHome(in: app, file: file, line: line)
        app.buttons["home.new-chat"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat.to"].firstMatch.waitForExistence(timeout: 15),
                      "New chat has its To row", file: file, line: line)
        let bot = app.buttons["new-chat.bot.\(botID)"].firstMatch
        XCTAssertTrue(bot.waitForExistence(timeout: 10), "New chat lists \(botID)", file: file, line: line)
        guard bot.exists else { return }
        bot.tap()
        XCTAssertTrue(app.descendants(matching: .any)["new-chat.to.chip.\(botID)"].firstMatch.waitForExistence(timeout: 10),
                      "\(botID) is in the To row", file: file, line: line)
    }

    /// A chat on the computer in use in the Chats list, by its session ID (`chats.row.here/<id>`;
    /// the old Sessions list's `session.row.<id>`).
    @MainActor
    func chatRow(_ sessionID: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["chats.row.here/\(sessionID)"].firstMatch
    }

    /// Leaves a pushed chat by its Back (`chat.back`).
    @MainActor
    func goBackFromChat(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["chat.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The chat has Back", file: file, line: line)
        guard back.exists else { return }
        back.tap()
    }

    /// The open chat's bot pill (`chat.identity`) opens the bot's page (`simple-bots.profile`).
    @MainActor
    func openBotPage(fromChatIn app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let identity = app.buttons["chat.identity"].firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10), "The chat names its bot", file: file, line: line)
        guard identity.exists else { return }
        identity.tap()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].firstMatch.waitForExistence(timeout: 10),
                      "The pill opens the bot's page", file: file, line: line)
    }

    // MARK: Old names, new doors

    /// An old ☰ destination by its row (`menu.chats`, `menu.agents`, `menu.scheduled-tasks`,
    /// `menu.kanban`, `menu.workflows`, `menu.projects`, `menu.feed|ideas|goals`, `menu.settings`)
    /// through the one home. Files (`menu.files`) lives on each bot's page now and has no door here.
    @MainActor
    func openRootDestination(_ destination: String, sidebarIdentifier: String,
                             in app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        openSidebarDestination(sidebarIdentifier, in: app, file: file, line: line)
    }

    /// The Bots view of the first tab, where the Agents screen's bots are now.
    @MainActor
    func openAgents(in app: XCUIApplication,
                    file: StaticString = #filePath, line: UInt = #line) {
        showBots(in: app, timeout: 10, file: file, line: line)
    }

    /// Settings, a sheet from the person's circle (`simple-bots.settings`) on each of the three tabs.
    @MainActor
    func openSettings(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // Already open: Settings is a sheet over the screen it was opened from.
        if app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 1) { return }
        let circle = app.buttons["simple-bots.settings"].firstMatch
        if !(circle.exists && circle.isHittable) { returnToHome(in: app, file: file, line: line) }
        XCTAssertTrue(circle.waitForExistence(timeout: 10), "The circle is on the home", file: file, line: line)
        guard circle.exists else { return }
        circle.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 5),
                      "The circle opens Settings.", file: file, line: line)
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

    /// There is no ☰ any more: a chat's places are the home's, so this leaves the chat for the home.
    @MainActor
    func openChatWorkspaceMenu(in app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        returnToHome(in: app, file: file, line: line)
    }

    /// An old ☰ row (`menu.<place>`) through the one home's door for that place.
    @MainActor
    func openSidebarDestination(_ identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let doors = ["menu.scheduled-tasks": "schedules", "menu.kanban": "tasks",
                     "menu.workflows": "workflows", "menu.projects": "projects"]
        let boards = ["menu.feed": "feed", "menu.ideas": "ideas", "menu.goals": "goals"]
        switch identifier {
        case "menu.chats", "menu.sessions": showChats(in: app, file: file, line: line)
        case "menu.agents": showBots(in: app, file: file, line: line)
        case "menu.settings": openSettings(in: app, file: file, line: line)
        case "menu.new-chat":
            returnToHome(in: app, file: file, line: line)
            app.buttons["home.new-chat"].firstMatch.tap()
        default:
            if let door = doors[identifier] {
                openWorkDoor(door, in: app, file: file, line: line)
            } else if let board = boards[identifier] {
                openTodayPanel(board, in: app, file: file, line: line)
            } else {
                XCTFail("\(identifier) has no place in the one home", file: file, line: line)
            }
        }
    }
}
