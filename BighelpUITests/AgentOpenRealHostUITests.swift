import XCTest

/// Tapping an agent opens its chat on the first tap, against two real hosts
/// (`BIGHELP_AGENT_OPEN_PROBE`: JSON with `address_a`, `address_b`, `agent`).
/// It only opens chats; it never sends a message. Skipped without the probe.
final class AgentOpenRealHostUITests: BighelpUITestCase {
    private var probe: [String: String] = [:]

    @MainActor func testAgentsOpenOnTheFirstTap() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_AGENT_OPEN_PROBE"] else {
            throw XCTSkip("Needs BIGHELP_AGENT_OPEN_PROBE")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        try addHost(app, address: try XCTUnwrap(probe["address_a"]), name: "Desk Hermes")
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.hosts"].tap()
        app.buttons["menu.host.add"].tap()
        try addHost(app, address: try XCTUnwrap(probe["address_b"]), name: "Lab Hermes")

        // Lab Hermes is selected; Desk Hermes' agent is on the other computer.
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 10))
        let agentName = try XCTUnwrap(probe["agent"])
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.agent.'")).firstMatch
            .waitForExistence(timeout: 45)
        Thread.sleep(forTimeInterval: 5)
        save("agent-open-0-list", app)
        for row in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fleet.'")).allElementsBoundByIndex {
            print("FLEET-ROW \(row.identifier) | \(row.label)")
        }
        var results: [String] = []
        for (step, host) in [("1-other-host", "Desk Hermes"), ("2-switch-back", "Lab Hermes"),
                             ("3-other-host-again", "Desk Hermes"), ("4-same-host", "Desk Hermes")] {
            let agent = fleetAgent(agentName, on: host, in: app)
            XCTAssertTrue(agent.waitForExistence(timeout: 45), "\(agentName) on \(host) is listed")
            agent.tap()
            let outcome = waitForOutcome(in: app)
            save("agent-open-\(step)", app)
            results.append("\(step): \(outcome)")
            if outcome == "error" { app.alerts.buttons["OK"].firstMatch.tap() }
            if outcome == "chat" { swipeBackFromLeadingEdge(in: app) }
            XCTAssertTrue(app.navigationBars["All agents"].waitForExistence(timeout: 15), "Back on All agents")
        }

        // One computer: Agents › an agent that isn't the one the app opens on.
        menu.tap()
        app.buttons["menu.all-hosts"].tap()
        openRootTab("tab.agents", in: app)
        let other = app.buttons["agent.\(probe["other_agent"] ?? "nova")"].firstMatch
        if other.waitForExistence(timeout: 20) {
            other.tap()
            let outcome = waitForOutcome(in: app)
            save("agent-open-5-single-host-other-agent", app)
            results.append("5-single-host-other-agent: \(outcome)")
        } else {
            save("agent-open-5-missing", app)
            results.append("5-single-host-other-agent: not found")
        }
        // New chat with any agent, including one whose Bot Chat the host can't give.
        for agentID in [probe["other_agent"] ?? "nova", "default"] {
            openRootTab("tab.agents", in: app)
            let row = app.buttons["agent.\(agentID)"].firstMatch
            guard row.waitForExistence(timeout: 20) else { results.append("new-chat-\(agentID): not found"); continue }
            row.tap()
            guard waitForOutcome(in: app) == "chat" else { results.append("new-chat-\(agentID): no chat"); continue }
            let newChat = chatNewChatButton(in: app)
            guard newChat.waitForExistence(timeout: 10) else { results.append("new-chat-\(agentID): no button"); continue }
            newChat.tap()
            confirmNewChatPicker(in: app)
            let alert = app.alerts.firstMatch
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !alert.exists { Thread.sleep(forTimeInterval: 0.3) }
            save("agent-open-6-new-chat-\(agentID)", app)
            let ok = !alert.exists && app.textViews["chat.composer.text"].exists
            results.append("new-chat-\(agentID): \(ok ? "chat" : "error \(alert.label)")")
            if alert.exists { alert.buttons.firstMatch.tap() }
        }
        let report = results.joined(separator: "\n")
        print("AGENT-OPEN-RESULTS\n\(report)")
        XCTAssertEqual(results.filter { !$0.hasSuffix(": chat") }, [], report)
    }

    /// "chat" when the composer shows, "error" for the Unable to open alert, "nothing" otherwise.
    @MainActor private func waitForOutcome(in app: XCUIApplication) -> String {
        let composer = app.textViews["chat.composer.text"]
        let alert = app.alerts.matching(NSPredicate(format: "label CONTAINS %@", "Unable to open")).firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if alert.exists { return "error" }
            if composer.exists { return "chat" }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return "nothing"
    }

    @MainActor private func fleetAgent(_ name: String, on host: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "(identifier BEGINSWITH 'fleet.agent.' OR identifier BEGINSWITH "
            + "'fleet.pinned.') AND label BEGINSWITH %@ AND label CONTAINS %@", name, host)).firstMatch
    }

    @MainActor private func addHost(_ app: XCUIApplication, address: String, name: String) throws {
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(address)
        app.buttons["More options"].firstMatch.tap()
        let nameField = app.textFields["host-setup.name"]
        if nameField.waitForExistence(timeout: 3) {
            nameField.tap()
            nameField.typeText(name + "\n")
        }
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected to \(name)")
        next.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AGENT_OPEN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
