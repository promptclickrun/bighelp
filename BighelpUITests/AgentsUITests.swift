import XCTest
import UIKit

final class AgentsUITests: BighelpUITestCase {
    @MainActor
    private func launch(appearance: String = "light", accessibility: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-test-agents-directory",
            "-loopdy.demo.appearance", appearance
        ]
        if accessibility {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        openAgents(in: app)
        XCTAssertTrue(revealSearchField(agentSearch(in: app), in: app))
        return app
    }

    @MainActor
    private func agentSearch(in app: XCUIApplication) -> XCUIElement {
        app.searchFields["Search agents and groups"].firstMatch
    }

    @MainActor
    func testAgentTapOpensChatRatherThanManagement() {
        let app = launch()
        let agent = app.buttons["agent.studio"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        agent.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["agent.actions"].exists)
    }

    @MainActor
    func testNativeSwipePinAndEditHaveVisibleManagementEquivalent() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap()
        search.typeText("Build\n")
        let row = app.buttons["agent.build"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3))
        pin.tap()

        app.buttons["agent.build.more"].tap()
        let unpin = app.buttons["agent.build.pin"]
        for _ in 0..<6 where !unpin.exists || !unpin.isHittable {
            app.descendants(matching: .any)["agent.actions.list"].firstMatch.swipeUp()
        }
        XCTAssertTrue(unpin.waitForExistence(timeout: 3))
        XCTAssertEqual(unpin.label, "Unpin")
        unpin.tap()
        XCTAssertTrue(unpin.waitForNonExistence(timeout: 3))

        row.swipeLeft()
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 5))
        app.buttons["agent.editor.cancel"].tap()
        XCTAssertTrue(app.textFields["agent.editor.name"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testGroupTapOpensChatAndSearchMatchesMembers() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap()
        search.typeText("Field Notes\n")
        let group = app.buttons["agents.group.research-circle"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(group.label.contains("3 agents"))
        group.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10))
    }

    /// On one computer every chat keeps the bottom bar, however Agents opened
    /// it: the pinned avatar, a new chat from the agent's row, or one of its
    /// existing chats. Only the chat's own Back replaces ☰.
    @MainActor
    func testChatsOpenedFromAgentsKeepTheTabBar() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        let directory = app.descendants(matching: .any)["agents.screen"].firstMatch

        openAgents(in: app)
        let avatar = app.descendants(matching: .any)["agents.featured.finance"].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 8))
        avatar.tap()
        assertChatKeepsTabBar("The avatar's chat", in: app)

        openAgents(in: app)
        let row = app.buttons["agent.travel"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { directory.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        assertChatKeepsTabBar("A new chat", in: app)

        openAgents(in: app)
        let more = app.buttons["agent.finance.more"]
        for _ in 0..<6 where !(more.exists && more.isHittable) { directory.swipeUp() }
        more.tap()
        let chats = app.buttons["agent.finance.sessions"]
        for _ in 0..<6 where !(chats.exists && chats.isHittable) {
            app.descendants(matching: .any)["agent.actions.list"].firstMatch.swipeUp()
        }
        chats.tap()
        let session = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(session.waitForExistence(timeout: 8))
        session.tap()
        assertChatKeepsTabBar("An existing chat", in: app)

        // The bar works from there: Feed leaves the chat.
        app.buttons["tab.feed"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["board.feed"].firstMatch.waitForExistence(timeout: 8))
    }

    @MainActor
    private func assertChatKeepsTabBar(_ chat: String, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "\(chat) didn't open", file: file, line: line)
        XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 5), "\(chat) has Back", file: file, line: line)
        // A new chat can focus the message box; the bar hides under the keyboard.
        if app.keyboards.firstMatch.exists {
            app.tables["chat.timeline"].swipeDown()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        }
        let feed = app.buttons["tab.feed"], chatTab = app.buttons["tab.sessions"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5) && feed.isHittable,
                      "\(chat) is missing the tab bar", file: file, line: line)
        if chatTab.exists {
            XCTAssertLessThanOrEqual(composer.frame.maxY, chatTab.frame.minY + 1,
                                     "\(chat): the message box sits above the tab bar", file: file, line: line)
        }
        // Evidence: BIGHELP_TABBAR_EVIDENCE (TEST_RUNNER_BIGHELP_TABBAR_EVIDENCE) names a folder.
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_TABBAR_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let name = chat.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "'", with: "")
            try? app.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("agents-\(name).png"))
        }
    }

    @MainActor
    func testGroupGesturesAndRenameMenu() {
        let app = launch()
        let search = agentSearch(in: app)
        search.tap(); search.typeText("Field Notes\n")
        let row = app.buttons["agents.group.research-circle"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3)); pin.tap()
        row.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 3))
        app.buttons["Unpin"].tap()
        row.press(forDuration: 1)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.alerts["Rename group"].waitForExistence(timeout: 3))
        let name = app.alerts.textFields.firstMatch
        name.tap(); name.typeText(" Renamed")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let renamed = NSPredicate(format: "label CONTAINS %@", "Renamed")
        expectation(for: renamed, evaluatedWith: row)
        waitForExpectations(timeout: 5)
        row.swipeLeft()
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 3)); archive.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        app.buttons["agents.groups.archived-toggle"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        app.buttons["Unarchive"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
    }

    /// A new agent starts from scratch, one of the built-in personalities (the
    /// typed name goes into it), or a template saved from an existing agent.
    @MainActor
    func testNewAgentStartsFromScratchATemplateOrASavedTemplate() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            if appearance == "light" {
                // Save an agent as a template first, so My templates has one.
                app.buttons["agent.studio.more"].tap()
                app.buttons["agent.studio.edit"].tap()
                let saveTemplate = app.buttons["agent.editor.save-template"]
                XCTAssertTrue(app.textFields["agent.editor.name"].waitForExistence(timeout: 5))
                for _ in 0..<8 where !saveTemplate.isHittable { app.swipeUp() }
                saveTemplate.tap()
                let saved = app.alerts["Template saved"]
                XCTAssertTrue(saved.waitForExistence(timeout: 3))
                XCTAssertTrue(saved.staticTexts.element(boundBy: 1).label.contains("choose My templates"))
                saved.buttons.firstMatch.tap()
                app.buttons["agent.editor.cancel"].tap()
                XCTAssertTrue(app.textFields["agent.editor.name"].waitForNonExistence(timeout: 3))
            }

            app.buttons["agents.create"].tap()
            let name = app.textFields["agent.editor.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            let start = app.segmentedControls["agent.editor.start"]
            XCTAssertTrue(start.exists)
            XCTAssertTrue(start.buttons["Scratch"].isSelected, "A new agent starts from scratch")
            if appearance == "light" { evidence("scratch", app) }

            start.buttons["Templates"].tap()
            let anchor = app.buttons["agent.editor.template.anchor"]
            XCTAssertTrue(anchor.waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["agent.editor.template.fable"].exists, "All fifteen are offered")
            anchor.tap()
            XCTAssertEqual(app.textFields["agent.editor.role"].value as? String, "Everyday generalist")
            name.tap()
            name.typeText("Kai")
            let instructions = app.textViews["agent.editor.instructions"]
            XCTAssertTrue((instructions.value as? String)?.contains("You are Kai, a practical, warm AI assistant") == true,
                          "The name goes into the personality")
            XCTAssertFalse((instructions.value as? String)?.contains("{{agent_name}}") == true)
            evidence("templates-\(appearance)", app)
            // Dragging down into the keyboard puts it away (its Done bar isn't reachable from UI tests).
            app.swipeDown(velocity: .fast)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            app.swipeUp()
            app.swipeUp()
            evidence("instructions-\(appearance)", app)
            for _ in 0..<4 { app.swipeDown() }

            if appearance == "light" {
                start.buttons["My templates"].tap()
                let savedCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agent.editor.saved-template.'"))
                    .firstMatch
                XCTAssertTrue(savedCard.waitForExistence(timeout: 3))
                savedCard.tap()
                XCTAssertEqual(name.value as? String, "Kai", "A typed name is kept")
                evidence("my-templates", app)
                app.swipeUp()
                app.swipeUp()
                XCTAssertTrue(instructions.waitForExistence(timeout: 3))
                XCTAssertFalse((instructions.value as? String)?.contains("a practical, warm AI assistant") == true,
                               "The saved template's instructions replace the personality")
                for _ in 0..<4 { app.swipeDown() }

                start.buttons["Scratch"].tap()
                XCTAssertEqual(app.textFields["agent.editor.role"].value as? String, "e.g. Travel planner",
                               "Scratch clears what the template filled in")
            }
            app.buttons["agent.editor.cancel"].tap()
            let discard = app.buttons["Discard changes"]
            if discard.waitForExistence(timeout: 3) { discard.tap() }
            XCTAssertTrue(name.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    private func evidence(_ label: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "agent-start-\(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("agent-start-\(label).png"))
    }

    @MainActor
    func testEditorCancellationRequiresConfirmationOnlyForUnsavedChanges() {
        let app = launch()
        app.buttons["agent.studio.more"].tap()
        app.buttons["agent.studio.edit"].tap()
        let name = app.textFields["agent.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" Updated")
        app.buttons["agent.editor.cancel"].tap()
        let keep = app.buttons["Keep editing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        keep.tap()
        XCTAssertTrue(name.exists)
        XCTAssertTrue((name.value as? String)?.contains("Updated") == true)
        app.buttons["agent.editor.cancel"].tap()
        app.buttons["Discard changes"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testLastRowClearsSearchAndNavigationInPortraitAndLandscape() {
        verifyClearance(accessibility: false, appearance: "light")
    }

    @MainActor
    func testAccessibilityTextClearsSearchInDarkMode() {
        verifyClearance(accessibility: true, appearance: "dark")
    }

    @MainActor
    private func verifyClearance(accessibility: Bool, appearance: String) {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(appearance: appearance, accessibility: accessibility)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let list = app.descendants(matching: .any)["agents.screen"].firstMatch
            let lastRow = app.buttons["agent.long-name"]
            let search = agentSearch(in: app)
            XCTAssertTrue(revealSearchField(search, in: app))
            for _ in 0..<24 {
                if lastRow.exists, lastRow.isHittable { break }
                list.swipeUp()
            }
            XCTAssertTrue(lastRow.exists)
            XCTAssertTrue(lastRow.isHittable)
            let manage = app.buttons["agent.long-name.more"]
            XCTAssertGreaterThanOrEqual(manage.frame.width, 44)
            XCTAssertGreaterThanOrEqual(manage.frame.height, 44)
            XCTAssertTrue(app.frame.intersects(lastRow.frame))
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "agents-clearance-\(appearance)-\(orientation.rawValue)-ax-\(accessibility)"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
