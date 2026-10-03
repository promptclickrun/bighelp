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
        // Older flows start on the chat list; the agent-home tests opt back in.
        if !launchArguments.contains("-loopdy.home.opens-chat") {
            launchArguments += ["-loopdy.home.opens-chat", "NO"]
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

    /// Agents, Tasks and Settings left the iPhone bottom bar for ☰ (the chat
    /// list's leading button, or the home chat's menu). Bar tabs still tap directly.
    /// Who the chat is with: the big live avatar on iPhone, the name chip on
    /// iPad and in group chats.
    @MainActor
    func chatIdentity(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["agent.hero.avatar", "chat.identity"])).firstMatch
    }

    /// The chat header's New chat button (the big-avatar header on iPhone,
    /// the name-chip header on iPad).
    @MainActor
    func chatNewChatButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.home.new-chat", "chat.new-chat"])).firstMatch
    }

    /// The big header's New chat asks who to chat with, with the current
    /// agent already picked. Confirms it when it shows.
    @MainActor
    func confirmNewChatPicker(in app: XCUIApplication) {
        let start = app.buttons["bot-mode.create.submit"].firstMatch
        if start.waitForExistence(timeout: 3), start.isEnabled { start.tap() }
    }

    /// The header's status line ("Updating…" while a chat reloads).
    @MainActor
    func chatStatus(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier IN %@", ["agent.hero.name", "chat.identity"])).firstMatch
    }

    /// Chat Info (People & Chat). Every one-agent chat uses the big avatar
    /// header now, where Info lives in the ⋯ menu; group chats keep their
    /// identity button.
    @MainActor
    @discardableResult
    func openChatInfo(in app: XCUIApplication, timeout: TimeInterval = 8) -> Bool {
        // Group chats open their details from the header; one-agent chats keep
        // files, appearance and session tools in the ⋯ menu instead.
        let identity = app.buttons["chat.identity"].firstMatch
        guard identity.waitForExistence(timeout: timeout), identity.isHittable else { return false }
        identity.tap()
        return true
    }

    /// Opens the chat's ⋯ menu when it's closed and returns one of its items.
    @MainActor
    func chatMenuItem(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let item = app.buttons[identifier].firstMatch
        if item.exists, item.isHittable { return item }
        let options = app.buttons["chat.options"].firstMatch
        if options.waitForExistence(timeout: timeout) { options.tap() }
        _ = item.waitForExistence(timeout: timeout)
        return item
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

    @MainActor
    func openRootTab(_ identifier: String, in app: XCUIApplication, timeout: TimeInterval = 20,
                     file: StaticString = #filePath, line: UInt = #line) {
        let drawerRows = ["tab.agents": "menu.agents", "tab.scheduled-tasks": "menu.scheduled-tasks",
                          "tab.profile": "menu.settings"]
        let sidebar = ["tab.sessions": "chats", "tab.agents": "agents",
                       "tab.scheduled-tasks": "scheduledTasks", "tab.profile": "settings"]
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            let direct = app.buttons[identifier].firstMatch
            if direct.exists, direct.isHittable { direct.tap(); return }
            if let id = sidebar[identifier], app.buttons["root.destination.\(id)"].firstMatch.isHittable {
                app.buttons["root.destination.\(id)"].firstMatch.tap()
                return
            }
            if let row = drawerRows[identifier] {
                let menu = [app.buttons["home.drawer.open"].firstMatch, app.buttons["chat.menu"].firstMatch]
                    .first { $0.exists && $0.isHittable }
                if let menu {
                    menu.tap()
                    let item = app.buttons[row].firstMatch
                    let list = app.descendants(matching: .any)["navigation.menu"].firstMatch
                    _ = list.waitForExistence(timeout: 10)
                    // Hosts come first, so later rows can sit below the fold.
                    for _ in 0..<6 where !(item.exists && item.isHittable) { list.swipeUp() }
                    XCTAssertTrue(item.waitForExistence(timeout: 10), "Missing \(row)", file: file, line: line)
                    item.tap()
                    return
                }
                // Feed, Ideas, Goals and Apps have no ☰; Chat does. A chat
                // opened from the list has Back instead.
                let back = app.buttons["chat.back"].firstMatch
                let chat = app.buttons["tab.sessions"].firstMatch
                // A pushed page (Activity, a task) has the system Back button.
                let navigationBack = app.navigationBars.firstMatch.buttons.firstMatch
                if back.exists, back.isHittable { back.tap() } else if chat.exists, chat.isHittable { chat.tap() }
                else if navigationBack.exists, navigationBack.isHittable, navigationBack.frame.minX < 60 {
                    navigationBack.tap()
                }
            }
            usleep(300_000)
        } while Date.now < deadline
        XCTFail("Could not open \(identifier)", file: file, line: line)
    }

    @MainActor
    func dismissActionsAfterWorkspaceSelection(in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        // Selecting a workspace asynchronously returns this embedded picker
        // to the action menu; it does not dismiss the enclosing sheet.
        let mainAction = app.buttons["chat.action.workspace"]
        let selectionFinished = mainAction.waitForExistence(timeout: 5)
        XCTAssertTrue(selectionFinished, "Workspace selection must finish before dismissing actions.",
                      file: file, line: line)
        guard selectionFinished else { return }
        let outside = app.otherElements["PopoverDismissRegion"].firstMatch
        if outside.exists && outside.isHittable {
            outside.tap()
        } else {
            let grabber = app.buttons["Sheet Grabber"]
            let canDismiss = grabber.waitForExistence(timeout: 3)
            XCTAssertTrue(canDismiss, "The action sheet must expose its dismissal handle.",
                          file: file, line: line)
            guard canDismiss else { return }
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            )
        }
        XCTAssertTrue(mainAction.waitForNonExistence(timeout: 3),
                      "Actions must close before interacting with the chat behind them.",
                      file: file, line: line)
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
    func testOpenReferencesSurvivesWorkspaceNavigation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat"]
        app.launch()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Before /")
        let drawer = app.otherElements["reference-hub.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        captureFailureEvidence(app, checkpoint: "before-workspace-tap")
        openChatWorkspaceMenu(in: app)
        captureFailureEvidence(app, checkpoint: "after-workspace-tap")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 5))
        let settingsRowInMenu = app.buttons["menu.settings"].firstMatch
        let settingsExist = settingsRowInMenu.waitForExistence(timeout: 5)
        if !settingsExist { captureFailureEvidence(app, checkpoint: "menu-settings-missing") }
        XCTAssertTrue(settingsExist)
        guard settingsExist else { return }
        settingsRowInMenu.tap()
        let tools = settingsRow("settings.hermes-tools", in: app)
        guard tools.exists else { return }
        tools.tap()
        let activity = app.buttons["workspace.open.activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()
        XCTAssertTrue(app.scrollViews["dashboard.screen"].waitForExistence(timeout: 5))
        openSidebarDestination("menu.chats", in: app)
        XCTAssertTrue(app.buttons["tab.sessions"].isSelected)
        XCTAssertEqual(app.state, .runningForeground)
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
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertFalse(app.buttons["quick-workspace.wiki"].exists)
        app.buttons["menu.new-chat"].tap()
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
    func testReferenceControlsAccessibilityAndLandscapeKeyboard() throws {
        try exerciseDrawer(appearance: "light", largeText: false, rotateAndAudit: true)
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
            ("hermes-tools", app.buttons["settings.hermes-tools"].firstMatch),
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
