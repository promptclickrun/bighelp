import XCTest

/// Settings › Default model on demo data.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class DefaultModelUITests: BighelpUITestCase {
    /// Pick an agent from the rail of cards to see and change its own default.
    @MainActor
    func testEachAgentsDefaultModelFromTheAgentRail() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openDefaultModel(in: app)

            let picker = app.buttons["models.agent"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Default model leads with the agent")
            XCTAssertEqual(picker.value as? String, "Avery Park")
            XCTAssertFalse(app.staticTexts["Profile"].exists, "Plain words: Agent, not Profile")
            picker.tap()
            let travel = app.buttons["models.agent.travel"]
            XCTAssertTrue(travel.waitForExistence(timeout: 5), "Every agent has a card")
            XCTAssertTrue(app.buttons["models.agent.finance"].isSelected)
            XCTAssertTrue(app.buttons["models.agent.home"].exists)
            evidence("agent-rail-\(appearance)", app)

            let main = app.buttons["models.main"]
            XCTAssertTrue(main.label.contains("Avery Park"), main.label)
            XCTAssertTrue((main.value as? String)?.contains("GPT") == true, String(describing: main.value))
            travel.tap()
            XCTAssertTrue(app.buttons["models.agent.travel"].isSelected)
            XCTAssertTrue(main.waitForExistence(timeout: 5))
            XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "Mina Shah")
                .evaluate(with: main), "The page shows the chosen agent's default: \(main.label)")
            XCTAssertTrue((main.value as? String)?.contains("Sonnet") == true, String(describing: main.value))
            evidence("agent-rail-travel-\(appearance)", app)

            guard appearance == "light" else { app.terminate(); continue }
            // Change Mina's default; Avery's stays as it was.
            main.tap()
            let surface = app.descendants(matching: .any)["model-picker.surface"].firstMatch
            XCTAssertTrue(surface.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["New chats with Mina Shah"].exists)
            app.buttons["model-picker.provider.nous"].tap()
            let hermes = app.buttons["model-picker.nous.Hermes-4-405B"]
            XCTAssertTrue(hermes.waitForExistence(timeout: 3))
            hermes.tap()
            let apply = app.buttons["model-picker.apply"]
            XCTAssertEqual(apply.label, "Save as default")
            apply.tap()
            XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
            XCTAssertTrue((main.value as? String)?.contains("405B") == true, String(describing: main.value))
            app.buttons["models.agent.finance"].tap()
            let backToAvery = NSPredicate(format: "label CONTAINS %@ AND value CONTAINS %@", "Avery Park", "GPT")
            expectation(for: backToAvery, evaluatedWith: main)
            waitForExpectations(timeout: 5)
            app.terminate()
        }
    }

    // MARK: - Steps

    @MainActor
    func openDefaultModel(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // A busy simulator can take a while to show the first screen.
        _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
            .firstMatch.waitForExistence(timeout: 60)
        openSettings(in: app, file: file, line: line)
        settingsRow("settings.default-model", in: app, file: file, line: line).tap()
        XCTAssertTrue(app.buttons["models.main"].waitForExistence(timeout: 10),
                      "Default model must load", file: file, line: line)
    }

    @MainActor
    private func openProviderKeysFromDefaultModel(in app: XCUIApplication,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        let open = app.buttons["models.open-provider-keys"]
        let list = app.descendants(matching: .any)["models.administration"].firstMatch
        for _ in 0..<6 where !(open.exists && open.isHittable) { list.swipeUp() }
        XCTAssertTrue(open.isHittable, "Default model offers Provider Keys", file: file, line: line)
        open.tap()
        XCTAssertTrue(app.navigationBars["Provider Keys"].waitForExistence(timeout: 8), file: file, line: line)
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    private func leaveAndComeBack(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor
    private func assertDefaultModelWorks(in app: XCUIApplication, _ when: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let reopen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Reopen this feature")).firstMatch
        let main = app.buttons["models.main"]
        let list = app.descendants(matching: .any)["models.administration"].firstMatch
        for _ in 0..<6 where list.exists && !(main.exists && main.isHittable) { list.swipeDown() }
        XCTAssertTrue(main.waitForExistence(timeout: 10), "Default model must still work \(when)", file: file, line: line)
        XCTAssertFalse(reopen.exists, "No \"Reopen this feature\" \(when)", file: file, line: line)
        XCTAssertTrue(main.isEnabled, "Its model can still be changed \(when)", file: file, line: line)
        evidence("default-model-\(when.replacingOccurrences(of: " ", with: "-"))", app)
    }

    @MainActor
    func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
