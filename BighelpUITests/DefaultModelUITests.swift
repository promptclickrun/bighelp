import XCTest

/// Settings › Default model on demo data. It used to turn into "Reopen this
/// feature after connecting to the selected host and profile." after a trip to
/// Provider Keys and back, or after leaving the app and coming back.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class DefaultModelUITests: BighelpUITestCase {
    @MainActor
    func testDefaultModelSurvivesProviderKeysAndComingBack() {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-demo-reconnects-on-return"]
        app.launch()
        openDefaultModel(in: app)

        openProviderKeysFromDefaultModel(in: app)
        goBack(in: app)
        assertDefaultModelWorks(in: app, "after Provider Keys and back")

        // Leaving the app reconnects; the page is still there when you're back.
        leaveAndComeBack(app)
        assertDefaultModelWorks(in: app, "after leaving the app and coming back")

        // And from Provider Keys, which is on top when you leave.
        openProviderKeysFromDefaultModel(in: app)
        leaveAndComeBack(app)
        XCTAssertTrue(app.navigationBars["Provider Keys"].waitForExistence(timeout: 5))
        goBack(in: app)
        assertDefaultModelWorks(in: app, "after leaving from Provider Keys and going back")
    }

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

    /// Settings › AI providers › Refresh model catalogs.
    @MainActor
    func testRefreshModelCatalogsFromAIProviders() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            settingsRow("settings.providers", in: app).tap()
            XCTAssertTrue(app.navigationBars["AI providers"].waitForExistence(timeout: 8))
            let more = app.buttons["providers.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 10), "In the top bar, beside Your providers")
            evidence("provider-keys-\(appearance)", app)
            more.tap()
            let refresh = app.buttons["Refresh model lists"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 5))
            refresh.tap()
            XCTAssertTrue(app.descendants(matching: .any)["providers.confirmed"].waitForExistence(timeout: 10),
                          "Hermes refreshed the catalogs")
            evidence("provider-keys-refreshed-\(appearance)", app)
            app.terminate()
        }
    }

    /// Settings › AI providers: your providers, each with Sign in again and Remove, and one
    /// Connect a provider button for the rest.
    @MainActor
    func testAIProvidersListsYoursAndConnectsNewOnes() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            settingsRow("settings.providers", in: app).tap()
            XCTAssertTrue(app.navigationBars["AI providers"].waitForExistence(timeout: 8))
            let nous = app.buttons["providers.connected.account:nous"]
            XCTAssertTrue(nous.waitForExistence(timeout: 10), "The demo host is signed in to Nous Portal")
            XCTAssertTrue(app.buttons["providers.connected.key:OPENROUTER_API_KEY"].exists, "and has an OpenRouter key")
            XCTAssertFalse(app.buttons["providers.sign-in.openai-codex"].exists, "Sign-ins wait under Connect a provider")
            evidence("ai-providers-\(appearance)", app)

            nous.tap()
            XCTAssertTrue(app.buttons["Sign in again"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Remove"].exists)
            evidence("ai-providers-menu-\(appearance)", app)
            app.buttons["Sign in again"].tap()
            // The demo host approves at once, so the code may already be gone.
            let signedIn = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR label == %@", "providers.confirmed", "WDJB-MJHT")).firstMatch
            XCTAssertTrue(signedIn.waitForExistence(timeout: 10), "Signing in again runs the sign-in")
            evidence("ai-providers-sign-in-again-\(appearance)", app)
            if app.staticTexts["WDJB-MJHT"].exists { app.swipeDown(velocity: .fast) }

            let connect = app.buttons["providers.connect"]
            XCTAssertTrue(connect.waitForExistence(timeout: 10))
            connect.tap()
            XCTAssertTrue(app.buttons["providers.sign-in.openai-codex"].waitForExistence(timeout: 10),
                          "ChatGPT signs in here")
            XCTAssertFalse(app.buttons["providers.sign-in.nous"].exists, "Nous is already connected")
            evidence("ai-providers-connect-\(appearance)", app)
            let deepSeek = app.buttons["providers.key-choice.DEEPSEEK_API_KEY"]
            for _ in 0..<6 where !deepSeek.isHittable { app.swipeUp() }
            XCTAssertTrue(deepSeek.isHittable, "Providers with keys are here too")
            XCTAssertFalse(app.buttons["providers.key-choice.OPENROUTER_API_KEY"].exists, "OpenRouter's key is saved")
            evidence("ai-providers-connect-keys-\(appearance)", app)
            app.terminate()
        }
    }

    /// A real host's signed-in accounts show under Your providers. Set BIGHELP_PROVIDERS_HOST
    /// (TEST_RUNNER_…) to an open host's address and BIGHELP_PROVIDERS_EXPECT to the provider IDs
    /// it is signed in to, comma-separated. Uninstall bighelp from the simulator first.
    @MainActor
    func testAIProvidersShowsARealHostsSignedInAccounts() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["BIGHELP_PROVIDERS_HOST"] else {
            throw XCTSkip("Set BIGHELP_PROVIDERS_HOST to an open Hermes host's address")
        }
        let expected = (environment["BIGHELP_PROVIDERS_EXPECT"] ?? "").split(separator: ",").map(String.init)
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: address)
        openSettings(in: app)
        settingsRow("settings.providers", in: app).tap()
        XCTAssertTrue(app.navigationBars["AI providers"].waitForExistence(timeout: 15))
        for id in expected {
            XCTAssertTrue(app.buttons["providers.connected.account:\(id)"].waitForExistence(timeout: 30),
                          "\(id) is signed in on the host")
        }
        evidence("ai-providers-real-host", app)
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
