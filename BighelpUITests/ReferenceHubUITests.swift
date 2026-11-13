import Foundation
import UIKit
import XCTest

/// A test owns one defaults lifetime, including every app relaunch it performs.
/// The app consumes this token only in simulator fixture/onboarding launches.
/// Existing suites exercise host tools that now live behind Nerd Mode. Unless a
/// test states its own preference, launch with Nerd Mode on.
final class BighelpTestApplication: XCUIApplication {
    override func launch() {
        if !launchArguments.contains("-loopdy.settings.nerd-mode") {
            launchArguments += ["-loopdy.settings.nerd-mode", "YES"]
        }
        // The one home's settings are moved over from the old shell's once; tests start past that.
        if !launchArguments.contains("-bighelp.home.migrated-v1") {
            launchArguments += ["-bighelp.home.migrated-v1", "YES"]
        }
        // Tests start on the Chats list with the bar; a test pins its own place (bots, chats, today
        // or work, with `-bighelp.home.view bots|chats` under today or work).
        if !launchArguments.contains("-loopdy.home.landing") {
            launchArguments += ["-loopdy.home.landing", "chats"]
        }
        // The computer in use only; tests of every computer at once opt in.
        if !launchArguments.contains("-bighelp.hosts.all-hosts") {
            launchArguments += ["-bighelp.hosts.all-hosts", "NO"]
        }
        // A bot profile's one-time swipe tutorial dims the page; tests of it opt back in.
        if !launchArguments.contains("-bighelp.dashboard.swipe-tutorial-seen") {
            launchArguments += ["-bighelp.dashboard.swipe-tutorial-seen", "YES"]
        }
        // For A/B runs: TEST_RUNNER_BIGHELP_UI_EXTRA_ARGS="-loopdy.chat.agentIsland NO".
        if let extra = ProcessInfo.processInfo.environment["BIGHELP_UI_EXTRA_ARGS"], !extra.isEmpty {
            launchArguments += extra.split(separator: " ").map(String.init)
        }
        super.launch()
    }
}

class BighelpUITestCase: XCTestCase {
    private let fixtureRunID = UUID().uuidString

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    @MainActor
    func makeApp() -> XCUIApplication {
        let app = BighelpTestApplication()
        app.launchEnvironment["BIGHELP_UI_TEST_RUN_ID"] = fixtureRunID
        return app
    }

    /// Who the chat is with: the pill in a chat's header (a bot's opens its page).
    @MainActor
    func chatIdentity(in app: XCUIApplication) -> XCUIElement {
        app.buttons["chat.identity"].firstMatch
    }

    /// The bar's New chat. Chats have no New chat of their own, so this leaves an open chat (its
    /// Back) first; the bar shows again under it.
    @MainActor
    func chatNewChatButton(in app: XCUIApplication) -> XCUIElement {
        let back = app.buttons["chat.back"].firstMatch
        if back.exists, back.isHittable {
            back.tap()
            _ = back.waitForNonExistence(timeout: 5)
        }
        return app.buttons["home.new-chat"].firstMatch
    }

    /// New chat opens with nobody picked: picks `botID`'s `new-chat.bot.<id>`, or the first bot listed.
    @MainActor
    func confirmNewChatPicker(in app: XCUIApplication, botID: String? = nil) {
        guard app.descendants(matching: .any)["new-chat.to"].firstMatch.waitForExistence(timeout: 5) else { return }
        let bot = botID.map { app.buttons["new-chat.bot.\($0)"].firstMatch }
            ?? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "new-chat.bot.")).firstMatch
        if bot.waitForExistence(timeout: 5), bot.isHittable { bot.tap() }
    }

    /// The header's status (the pill's value reads "Updating…" while a chat reloads).
    @MainActor
    func chatStatus(in app: XCUIApplication) -> XCUIElement {
        app.buttons["chat.identity"].firstMatch
    }
    /// Chat Info (People & Chat): a group chat's members. One-agent chats have
    /// none; everything it held is in their ⋯ menu.
    @MainActor
    @discardableResult
    func openChatInfo(in app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        // ⋯ › Chat info in a group chat (its name opens it too).
        let item = chatMenuItem("chat.info", in: app, timeout: timeout)
        guard item.exists, item.isHittable else { return false }
        item.tap()
        return true
    }

    /// ⋯ › Usage › Compact. A menu item can report its title instead of its identifier.
    @MainActor
    func chatCompactItem(in app: XCUIApplication) -> XCUIElement {
        chatMenuItem("chat.compact", in: app)
    }

    /// Opens the chat's ⋯ menu when it's closed and returns one of its items. The chat's
    /// actions sit at the top level; at accessibility sizes they're in This chat and Agent, and
    /// Usage, File changes and Advanced in More.
    @MainActor
    func chatMenuItem(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        func shown() -> XCUIElement? {
            let item = chatMenuElement(identifier, in: app)
            return item.exists && item.isHittable ? item : nil
        }
        if let item = shown() { return item }
        let groups: [String]
        switch identifier {
        case "chat.session-controls", "chat.fast-mode": groups = ["chat.options.model-speed"]
        case "chat.context-window", "chat.provider-usage", "chat.compact":
            groups = ["chat.options.more", "chat.options.usage"]
        case "chat.info", "chat.group-settings", "chat.rename", "chat.move-project", "chat.files":
            groups = ["chat.options.this-chat"]
        case "chat.bot-page", "chat.new-bot-chat": groups = ["chat.options.agent"]
        case "chat.options.usage", "chat.options.advanced", "chat.file-changes": groups = ["chat.options.more"]
        case "chat.force-refresh", "chat.options.display": groups = ["chat.options.more", "chat.options.advanced"]
        case "chat.visibility.reasoning", "chat.visibility.tool-calls": groups = ["chat.options.more", "chat.options.advanced", "chat.options.display"]
        default: groups = []
        }
        let isOpen = ["chat.options.this-chat", "chat.options.agent", "chat.options.more", "chat.options.advanced"]
            .contains { chatMenuElement($0, in: app).exists }
        if !isOpen {
            let options = app.buttons["chat.options"].firstMatch
            if options.waitForExistence(timeout: timeout) { options.tap() }
        }
        for group in groups {
            if chatMenuElement(identifier, in: app).waitForExistence(timeout: 1), let item = shown() { return item }
            // The menu animates open: wait for each submenu before its tap, or the tap is skipped.
            let submenu = chatMenuElement(group, in: app)
            if submenu.waitForExistence(timeout: 3), submenu.isHittable { submenu.tap() }
        }
        let item = chatMenuElement(identifier, in: app)
        _ = item.waitForExistence(timeout: timeout)
        return item
    }

    /// Native menu rows often report their title (then a subtitle after a comma, a dot or a colon)
    /// instead of their identifier, so look for both. Accessibility sizes use the shorter titles.
    @MainActor
    func chatMenuElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let titles: [String: [String]] = [
            "chat.info": ["Chat info"], "chat.group-settings": ["Group Settings"], "chat.rename": ["Rename…"], "chat.move-project": ["Move to Project…", "Move…"],
            "chat.files": ["Files"], "chat.bot-page": ["Bot page"],
            "chat.new-bot-chat": ["New Bot Chat"], "chat.compact": ["Compact"],
            "chat.file-changes": ["File changes"], "chat.options.usage": ["Usage"], "chat.options.advanced": ["Advanced"],
            "chat.options.model-speed": ["Model & speed", "Model"], "chat.session-controls": ["Model settings", "Model"],
            "chat.fast-mode": ["Fast Mode"], "chat.fast-mode.on": ["On"], "chat.fast-mode.off": ["Off"],
            "chat.context-window": ["Context window"], "chat.provider-usage": ["Usage"],
            "chat.options.display": ["Display"], "chat.visibility.reasoning": ["Show reasoning", "Reasoning"],
            "chat.visibility.tool-calls": ["Show tool calls", "Tool calls"],
            "chat.force-refresh": ["Force refresh", "Refresh"],
        ]
        guard let names = titles[identifier] else { return app.buttons[identifier].firstMatch }
        let byTitle = names.map { title in
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                        title, title + ", ", title + " ·", title + ":")
        }
        let matches = app.buttons.matching(NSCompoundPredicate(orPredicateWithSubpredicates:
            [NSPredicate(format: "identifier == %@", identifier)] + byTitle))
        // ⋯ › Usage › Usage shares its submenu's title: it's the second "Usage" once the submenu is open.
        if identifier == "chat.provider-usage" {
            return matches.count > 1 ? matches.element(boundBy: 1) : app.buttons[identifier].firstMatch
        }
        return matches.firstMatch
    }

    /// Leaves a pushed chat by its Back (`chat.back`), top left in its header.
    @MainActor
    func swipeBackFromLeadingEdge(in app: XCUIApplication) {
        let back = app.buttons["chat.back"].firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    /// ⋯ › Context window (Nerd Mode, a chat with context). Returns the pop-up.
    @MainActor
    @discardableResult
    func openContextWindow(in app: XCUIApplication, timeout: TimeInterval = 8) -> XCUIElement {
        let item = chatMenuItem("chat.context-window", in: app, timeout: timeout)
        if item.exists { item.tap() }
        let popover = app.descendants(matching: .any)["chat.session-context.popover"].firstMatch
        _ = popover.waitForExistence(timeout: timeout)
        return popover
    }

    /// The old shell's tabs, through the one home's doors: `tab.sessions` is Chats and `tab.agents`
    /// Bots (the first tab's switch), `tab.feed|ideas|goals` Today's panel on that board,
    /// `tab.scheduled-tasks`, `tab.kanban`, `tab.workflows` and `tab.projects` Work's doors, and
    /// `tab.profile` Settings (the circle). Anything else has no place now and fails.
    @MainActor
    func openRootTab(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line) {
        let doors = ["tab.scheduled-tasks": "schedules", "tab.kanban": "tasks",
                     "tab.workflows": "workflows", "tab.projects": "projects"]
        let boards = ["tab.feed": "feed", "tab.ideas": "ideas", "tab.goals": "goals"]
        switch identifier {
        case "tab.sessions", "tab.session-list": showChats(in: app, timeout: timeout, file: file, line: line)
        case "tab.agents": showBots(in: app, timeout: timeout, file: file, line: line)
        case "tab.profile": openSettings(in: app, file: file, line: line)
        default:
            if let door = doors[identifier] {
                openWorkDoor(door, in: app, timeout: timeout, file: file, line: line)
            } else if let board = boards[identifier] {
                openTodayPanel(board, in: app, timeout: timeout, file: file, line: line)
            } else {
                XCTFail("\(identifier) has no place in the one home", file: file, line: line)
            }
        }
    }

    @MainActor
    func settingsRow(_ identifier: String, in app: XCUIApplication,
                     file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let row = app.buttons[identifier]
        let settings = app.descendants(matching: .any)["settings.screen"].firstMatch
        let screenExists = settings.waitForExistence(timeout: 5)
        XCTAssertTrue(screenExists, "Settings screen must be visible before finding a row.",
                      file: file, line: line)
        guard screenExists else { return row }
        // A SwiftUI Form can expose table or collection semantics. Scroll the
        // identified settings surface instead of assuming a ScrollView type.
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            settings.swipeUp()
        }
        // Returning from a destination or checking a previous row can leave
        // that row above the current viewport rather than below it.
        for _ in 0..<8 where !(row.exists && row.isHittable) {
            settings.swipeDown()
        }
        XCTAssertTrue(row.exists && row.isHittable, "Settings row must be reachable: \(identifier)",
                      file: file, line: line)
        return row
    }
}

final class ReferenceHubUITests: BighelpUITestCase {
    @MainActor
    func testMiddleSlashCommandWorksWithoutRetiredProviders() throws {
        try exerciseDrawer(appearance: "light", largeText: false)
    }

    /// A lone slash lists every command, and the list shows them: it once kept to two rows.
    @MainActor
    func testTheCommandListTakesTheRoomAboveTheMessageBox() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        startNewChat(with: "finance", in: app)
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("/")
        let drawer = app.otherElements["reference-hub.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reference-hub.command."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "reference-hub-command-list-height"
        evidence.lifetime = .keepAlways
        add(evidence)
        let note = XCTAttachment(string: "drawer \(drawer.frame) editor \(editor.frame) keyboard \(app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame : .zero) rows \(rows.count)")
        note.name = "reference-hub-command-list-frames"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY, "The message box stays over the keyboard")
        for index in 0..<rows.count {
            let row = rows.element(boundBy: index)
            XCTAssertGreaterThanOrEqual(row.frame.minY, drawer.frame.minY, "Row \(index) is inside the list")
            XCTAssertLessThanOrEqual(row.frame.maxY, drawer.frame.maxY + 1, "Row \(index) shows whole")
        }
    }

    @MainActor
    func testDarkLargeTextDrawerPreservesKeyboardAndDraft() throws {
        try exerciseDrawer(appearance: "dark", largeText: true)
    }

    @MainActor
    func testSendKeepsKeyboardClosedWhileChatUpdates() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Please summarize this fixture conversation")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.keyboards.firstMatch.exists
        }, object: nil)
        reopened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(editor.value as? String, "")
    }

    @MainActor
    private func exerciseDrawer(appearance: String, largeText: Bool, rotateAndAudit: Bool = false) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays",
            "-loopdy.appearance.theme", "loopdy", "-loopdy.demo.appearance", appearance]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        startNewChat(with: "finance", in: app)
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Before /")
        let drawer = app.otherElements["reference-hub.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        captureFailureEvidence(app, checkpoint: "before-commands-filter-tap")
        XCTAssertFalse(app.buttons["reference-hub.filter.wiki"].exists)
        XCTAssertFalse(app.buttons["reference-hub.filter.repos"].exists)
        app.buttons["reference-hub.filter.commands"].tap()
        captureFailureEvidence(app, checkpoint: "after-commands-filter-tap")
        if rotateAndAudit {
            try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait]) { issue in
                guard let element = issue.element else { return false }
                return !element.identifier.hasPrefix("reference-hub.")
                    && !element.identifier.hasPrefix("chat.composer.")
            }
        }
        let command = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reference-hub.command.")).firstMatch
        let commandExists = command.waitForExistence(timeout: 5)
        if !commandExists { captureFailureEvidence(app, checkpoint: "command-row-missing") }
        XCTAssertTrue(commandExists)
        guard commandExists else { return }
        command.tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["reference-hub.command.insert"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Selection must preserve the keyboard")
        XCTAssertTrue((editor.value as? String)?.hasPrefix("Before /") == true)
        editor.typeText("after")
        XCTAssertTrue((editor.value as? String)?.hasSuffix("after") == true)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        if rotateAndAudit {
            let preserved = editor.value as? String
            XCUIDevice.shared.orientation = .landscapeLeft
            defer { XCUIDevice.shared.orientation = .portrait }
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height && editor.frame.height > 0
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertEqual(editor.value as? String, preserved)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            XCTAssertGreaterThan(editor.frame.height, 0)
            XCTAssertLessThanOrEqual(editor.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            editor.typeText(" rotated")
            XCTAssertTrue((editor.value as? String)?.hasSuffix(" rotated") == true)
            let screen = XCUIScreen.main.screenshot()
            let oriented = UIGraphicsImageRenderer(size: app.frame.size).image { _ in
                screen.image.draw(in: CGRect(origin: .zero, size: app.frame.size))
            }
            let rotatedEvidence = XCTAttachment(image: oriented)
            rotatedEvidence.name = "reference-composer-landscape-keyboard"
            rotatedEvidence.lifetime = .keepAlways
            add(rotatedEvidence)
        }
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "reference-hub-native-command-middle-\(appearance)-\(largeText ? "large" : "standard")"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    @MainActor
    private func captureFailureEvidence(_ app: XCUIApplication, checkpoint: String) {
        // These tests use synthetic fixture drafts. Capture before an action as
        // well as after it so a later failed tap cannot erase the useful state.
        let elements: [(String, XCUIElement)] = [
            ("keyboard", app.keyboards.firstMatch),
            ("drawer", app.otherElements["reference-hub.drawer"]),
            ("editor", app.textViews["chat.composer.text"]),
            ("commands-filter", app.buttons["reference-hub.filter.commands"]),
            ("first-command", app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "reference-hub.command.")).firstMatch),
            ("options", app.buttons["chat.options"]),
        ]
        var details = "Checkpoint: \(checkpoint)\nApp state: \(app.state.rawValue)\nApp frame: \(app.frame)\n"
        for (name, element) in elements {
            if element.exists {
                details += "\(name): frame=\(element.frame), hittable=\(element.isHittable), "
                    + "selected=\(element.isSelected), label=\(element.label), value=\(String(describing: element.value))\n"
            } else {
                details += "\(name): absent\n"
            }
        }
        details += "\nAccessibility hierarchy:\n\(app.debugDescription)"
        let hierarchy = XCTAttachment(string: details)
        hierarchy.name = "reference-hub-\(checkpoint)-hierarchy"
        hierarchy.lifetime = .deleteOnSuccess
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reference-hub-\(checkpoint)-screenshot"
        screenshot.lifetime = .deleteOnSuccess
        add(screenshot)
    }
}
