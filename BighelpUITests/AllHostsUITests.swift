import XCTest

/// The all-hosts view: ☰'s switch lists every agent on every host with its
/// host tagged, a tap opens that agent's chat, and a one-host screen like
/// Settings asks which host first. Demo hosts: Home Hermes (the demo's own
/// agents), Studio Mac (sample agents) and Office Linux (out of reach).
/// Set BIGHELP_FLEET_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class AllHostsUITests: BighelpUITestCase {
    @MainActor
    func testAllHostsListOpensAgentsAndAsksWhichHostForSettings() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()

        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let toggle = app.buttons["menu.all-hosts"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.label, "Show all hosts", "Several bots: a tap shows every host")
        toggle.tap()

        XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5))
        let mina = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        XCTAssertTrue(mina.label.contains("Home Hermes"), mina.label)
        let sage = app.buttons["fleet.agent.Sage Ortiz"]
        XCTAssertTrue(sage.waitForExistence(timeout: 5), "Another host's agents are listed too")
        XCTAssertTrue(sage.label.contains("Studio Mac"), sage.label)
        XCTAssertTrue(app.descendants(matching: .any)["fleet.host-note.Office Linux"].exists,
                      "A host out of reach says so")
        XCTAssertTrue(mina.label.contains("Travel agent"), "Each agent's role shows under its name: \(mina.label)")
        XCTAssertTrue(app.buttons["fleet.new-chat"].isHittable, "One big New chat, bottom right")

        // Touch and hold a pinned agent and drag it: the new order stays.
        let pinned = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.pinned.'"))
        XCTAssertGreaterThanOrEqual(pinned.count, 2)
        let before = pinned.allElementsBoundByIndex.map(\.identifier)
        pinned.element(boundBy: 0).press(forDuration: 0.8, thenDragTo: pinned.element(boundBy: 1),
                                          withVelocity: .slow, thenHoldForDuration: 0.6)
        let after = pinned.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(after, [before[1], before[0]] + before.dropFirst(2), "Dragged into a new place")
        XCTAssertFalse(pinned.element(boundBy: 0).label.contains("Home Hermes"), "Pinned agents skip the host name")
        save("list", app)

        // A tap opens that agent's own chat. ☰ is top left, and an edge swipe goes back to the list.
        mina.tap()
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mina Shah"))
            .firstMatch.exists, "It's Mina's chat")
        XCTAssertTrue(app.buttons["chat.menu"].firstMatch.exists, "The chat has ☰")
        XCTAssertFalse(app.buttons["chat.back"].firstMatch.exists, "The chat has no Back button")
        swipeBackFromLeadingEdge(in: app)
        XCTAssertTrue(mina.waitForExistence(timeout: 5))

        // Settings belongs to one host: pick which.
        menu.tap()
        XCTAssertEqual(app.buttons["menu.all-hosts"].label, "Show one host", "One bot: a tap goes back to one host")
        app.buttons["menu.settings"].tap()
        let pickHome = app.buttons["fleet.gate.host.Home Hermes"]
        XCTAssertTrue(pickHome.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fleet.gate.host.Studio Mac"].exists)
        save("which-host", app)
        pickHome.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // ☰ › Agents is All agents here, right under New chat. One-host places (Projects,
        // Kanban, Scheduled tasks) and the one-host Agents row aren't in this menu.
        menu.tap()
        let agentsRow = app.buttons["menu.all-agents"]
        XCTAssertTrue(agentsRow.waitForExistence(timeout: 5))
        XCTAssertEqual(agentsRow.label, "Agents")
        XCTAssertLessThan(app.buttons["menu.new-chat"].frame.minY, agentsRow.frame.minY, "New chat comes first")
        for hidden in ["menu.agents", "menu.projects", "menu.kanban", "menu.new-group"] {
            XCTAssertFalse(app.buttons[hidden].exists, "\(hidden) isn't in the all-hosts menu")
        }
        save("menu-all-hosts", app)
        agentsRow.tap()
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5))

        // Off again: one host, its own chat list.
        XCTAssertEqual(app.buttons["fleet.toggle"].label, "Show one host")
        app.buttons["fleet.toggle"].tap()
        XCTAssertTrue(app.navigationBars["Sessions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["fleet.home"].exists)
    }

    /// Switching agents from a chat's header keeps the all-hosts view: the new
    /// agent's chat has ☰, an edge swipe goes back to All agents, and no one-host tab bar (Feed,
    /// Ideas, Goals), so nothing strands you on one host's screens.
    @MainActor
    func testSwitchingAgentFromChatStaysInAllHosts() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["menu.all-hosts"].waitForExistence(timeout: 5))
        save("menu-one-host", app)
        app.buttons["menu.all-hosts"].tap()
        let mina = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        save("list-with-one-bot-switch", app)
        mina.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.feed"].exists, "An all-hosts chat has the bottom menu, for this agent")

        app.buttons["agent.hero.name"].tap()
        let other = app.buttons["agent.switcher.agent.finance"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.menu"].firstMatch.waitForExistence(timeout: 5),
                      "The switched-to chat has ☰")
        XCTAssertTrue(app.buttons["tab.feed"].waitForExistence(timeout: 2),
                      "The switched-to agent's chat has its Feed, Ideas and Goals too")
        save("switched-agent", app)

        swipeBackFromLeadingEdge(in: app)
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 5), "An edge swipe returns to All agents")
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["menu.all-hosts"].waitForExistence(timeout: 5))
        save("menu-all-hosts", app)
    }

    /// Hold a pinned agent and let go to unpin it; long-press any agent's row to pin it.
    @MainActor
    func testPinnedAgentsCanBeUnpinnedAndPinnedAgain() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        for name in ["Rio Tanaka", "Avery Park"] { // another host's agent, then the selected host's
            let tile = app.descendants(matching: .any)["fleet.pinned.\(name)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "\(name) is pinned")
            tile.press(forDuration: 1.0)
            let unpin = app.buttons["Unpin"].firstMatch
            XCTAssertTrue(unpin.waitForExistence(timeout: 3), "Holding a pinned agent offers Unpin")
            unpin.tap()
            XCTAssertFalse(tile.waitForExistence(timeout: 2), "\(name) left the pinned agents")
            let row = app.buttons["fleet.agent.\(name)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "\(name) is in the list now")
        }
        let row = app.buttons["fleet.agent.Rio Tanaka"]
        row.press(forDuration: 1.0)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 3), "A row's menu offers Pin")
        pin.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.pinned.Rio Tanaka"].waitForExistence(timeout: 3),
                      "Pinned again")
    }

    /// A swipe that starts on the pinned agents scrolls the list like anywhere
    /// else; only touch and hold picks an agent up.
    @MainActor
    func testSwipingOnPinnedAgentsScrollsTheList() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "NO",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        let pinned = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.pinned.'"))
        XCTAssertTrue(pinned.firstMatch.waitForExistence(timeout: 5))
        let order = pinned.allElementsBoundByIndex.map(\.identifier)
        let tile = pinned.firstMatch

        // Control: a swipe on an agent row scrolls.
        let row = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowTop = row.frame.minY
        swipeUp(from: row, in: app)
        XCTAssertLessThan(row.frame.minY, rowTop - 40, "The list scrolls (control)")
        swipeDown(in: app)
        let tileTop = tile.frame.minY

        swipeUp(from: tile, in: app)
        // A list long enough scrolls the tiles out of view altogether.
        XCTAssertTrue(!tile.exists || tile.frame.minY < tileTop - 40,
                      "A swipe that starts on a pinned agent scrolls the list")
        swipeDown(in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCTAssertEqual(pinned.allElementsBoundByIndex.map(\.identifier), order, "A swipe doesn't rearrange them")
    }

    /// Hide an agent and show it again; file it into a new section; delete
    /// the section (the agent stays) and Undo. Demo hosts keep it on screen.
    @MainActor
    func testAgentsHideAndFileIntoSections() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES"]
        app.launch()

        let mina = app.buttons["fleet.agent.Mina Shah"]
        XCTAssertTrue(mina.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["fleet.group.Launch crew"].exists,
                      "Group chats list beside agents")
        shot("list", app)

        mina.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Hide from list"].waitForExistence(timeout: 5))
        shot("agent-menu", app)
        app.buttons["Hide from list"].tap()
        XCTAssertTrue(mina.waitForNonExistence(timeout: 5), "A hidden agent leaves the list")

        app.buttons["fleet.organize"].tap()
        let showHidden = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Show hidden agents (1)")).firstMatch
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        shot("organize-menu", app)
        showHidden.tap()
        XCTAssertTrue(mina.waitForExistence(timeout: 5), "Shown again, dimmed, to unhide")
        XCTAssertEqual(mina.value as? String, "Hidden")
        shot("hidden-shown", app)
        mina.press(forDuration: 1.0)
        app.buttons["Show in list"].tap()

        mina.press(forDuration: 1.0)
        app.buttons["Move to section"].tap()
        app.buttons["New section"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("new-section", app)
        field.typeText("Trips")
        app.alerts.buttons["Create"].firstMatch.tap()
        let trips = app.descendants(matching: .any)["fleet.section.Trips"]
        XCTAssertTrue(trips.waitForExistence(timeout: 5))
        shot("filed", app)

        app.buttons["fleet.section.menu.Trips"].tap()
        app.buttons["Delete section"].tap()
        XCTAssertTrue(trips.waitForNonExistence(timeout: 5))
        XCTAssertTrue(mina.exists, "Deleting a section never deletes its agents")
        let undo = app.buttons["fleet.section.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        shot("undo", app)
        undo.tap()
        XCTAssertTrue(trips.waitForExistence(timeout: 5))
    }

    /// Holding a pinned agent and holding an agent's row show the same kind
    /// of menu, readable in light and dark.
    @MainActor
    func testHoldingPinnedAgentShowsItsMenu() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let tile = app.descendants(matching: .any)["fleet.pinned.Avery Park"]
            XCTAssertTrue(tile.waitForExistence(timeout: 10))
            tile.press(forDuration: 1.0)
            XCTAssertTrue(app.buttons["Unpin"].firstMatch.waitForExistence(timeout: 3), "Holding a pinned agent offers Unpin")
            XCTAssertTrue(app.buttons["Hide from list"].firstMatch.exists, "The same menu as the agent's row")
            XCTAssertTrue(app.buttons["Move to section"].firstMatch.exists)
            sleep(1)
            shot("pinned-menu-\(appearance)", app)
            app.terminate()

            app.launch()
            let row = app.buttons["fleet.agent.Mina Shah"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.press(forDuration: 1.0)
            XCTAssertTrue(app.buttons["Pin"].firstMatch.waitForExistence(timeout: 3))
            sleep(1)
            shot("row-menu-\(appearance)", app)
            app.terminate()
        }
    }

    /// New chat picks one agent and opens its chat. Its Group chat button
    /// picks several agents on one host instead, and Create chat makes the
    /// group and opens it. Organize no longer starts group chats.
    @MainActor
    func testNewChatPicksOneAgentOrSeveralForAGroup() throws {
        for appearance in ["light", "dark"] { newChatPicksOneAgentOrSeveralForAGroup(appearance) }
    }

    @MainActor
    private func newChatPicksOneAgentOrSeveralForAGroup(_ appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.hosts.all-hosts", "YES",
                               "-preview-group-create", // demo group chats can be created
                               "-loopdy.demo.appearance", appearance]
        app.launch()

        let organize = app.buttons["fleet.organize"]
        XCTAssertTrue(organize.waitForExistence(timeout: 10))
        organize.tap()
        XCTAssertTrue(app.buttons["fleet.organize.new-section"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["fleet.organize.new-group"].exists, "Group chats start from New chat now")
        XCTAssertFalse(app.buttons["New group chat"].exists)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()

        // One agent: its chat opens, as before.
        let newChat = app.buttons["fleet.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let avery = app.buttons["fleet.new-chat.Avery Park"]
        XCTAssertTrue(avery.waitForExistence(timeout: 5))
        shot("new-chat-\(appearance)", app)
        avery.tap()
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 10), "Avery's new chat opens")
        swipeBackFromLeadingEdge(in: app)

        // Several agents: Group chat, pick, Create chat.
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        let group = app.buttons["fleet.new-chat.group"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let create = app.buttons["fleet.new-chat.create-group"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled, "Nobody picked yet")
        let mina = app.buttons["fleet.new-chat.Mina Shah"]
        mina.tap()
        XCTAssertEqual(mina.value as? String, "Selected")
        XCTAssertFalse(create.isEnabled, "One agent isn't a group")
        XCTAssertFalse(app.buttons["fleet.new-chat.Sage Ortiz"].isEnabled, "Another host's agents can't join this group")
        app.buttons["fleet.new-chat.Avery Park"].tap()
        XCTAssertTrue(create.isEnabled)
        shot("new-group-picked-\(appearance)", app)
        create.tap()
        XCTAssertTrue(app.buttons["chat.people"].waitForExistence(timeout: 10), "The new group chat opens")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Mina Shah & Avery Park")).firstMatch.exists,
                      "It's named after its agents")
        shot("new-group-chat-\(appearance)", app)
        app.terminate()
    }

    /// Saves a screenshot into TEST_RUNNER_BIGHELP_FLEET_SHOTS when set.
    @MainActor
    private func shot(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_FLEET_SHOTS"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @MainActor
    private func swipeUp(from element: XCUIElement, in app: XCUIApplication) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
    }

    @MainActor
    private func swipeDown(in app: XCUIApplication) {
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        sleep(1)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard ProcessInfo.processInfo.environment["BIGHELP_FLEET_EVIDENCE"] != nil else { return }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "all-hosts-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
