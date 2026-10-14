import XCTest

/// Ask an agent on a gateway bighelp isn't using: bighelp switches to it, waits for it to
/// connect and the agent answers. Before the fix it failed at once ("couldn't reach your
/// host") because the switch had already started connecting. Runs Ask an agent's own steps
/// through `-test-shortcut-ask` (XCUITest can't run a Shortcut to its answer in the
/// simulator), against two real, isolated Hermes hosts from
/// `Scripts/HostSignInMatrixProbe.py --modes fleet` (BIGHELP_SIGNIN_PROBE); skipped without it.
final class ShortcutGatewaySwitchHostUITests: BighelpUITestCase {
    @MainActor func testAskAnAgentSwitchesToItsGatewayAndGetsTheAnswer() throws {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes fleet")
        }
        let probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "fleet" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "Password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        // No demo data: the Shortcut sees the gateways bighelp really has.
        let app = makeApp()
        app.launchArguments = ["-test-no-configured-hosts", "-bighelp.hosts.all-hosts", "NO"]
        app.launch()
        try onboardOpenHost(app, address: try XCTUnwrap(probe["address_a"]))
        addAnotherHost(in: app)
        try addHost(app, address: try XCTUnwrap(probe["address_b"]), name: "Lab Hermes")
        XCTAssertTrue(app.buttons["home.drawer.open"].waitForExistence(timeout: 30))
        save("1-lab-in-use", app)

        // Lab Hermes is in use; the Shortcut asks on the first host (named by its address).
        app.terminate()
        let other = try XCTUnwrap(probe["address_a"]).components(separatedBy: ":")[0]
        app.launchArguments = ["-bighelp.hosts.all-hosts", "NO", "-test-shortcut-ask", other]
        app.launch()
        let answer = app.alerts["Ask an agent"]
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "Ask an agent finishes")
        save("2-answer", app)
        let text = answer.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(text.contains("fixture complete"), "The agent on the other gateway answers: \(text)")
    }

    /// Add host from ☰'s host switcher, after a fresh launch so setup's screens are gone.
    @MainActor private func addAnotherHost(in app: XCUIApplication) {
        app.terminate()
        app.launch()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        sleep(3)
        let hosts = app.buttons["menu.hosts"]
        for _ in 0..<3 where !hosts.exists {
            menu.tap()
            _ = hosts.waitForExistence(timeout: 8)
        }
        hosts.tap()
        app.buttons["menu.host.add"].tap()
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
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected to \(address)")
        next.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("shortcut-\(name).png"))
    }
}
