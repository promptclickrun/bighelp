import XCTest

/// Settings › Models (Default model and AI providers both open it) on demo data: the providers, a row
/// for each bot's default model that opens its Default Model page, and with Advanced options Refresh
/// model lists. It used to turn into "Reopen this feature after connecting to the selected host and
/// profile." after leaving the app and coming back.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class DefaultModelUITests: BighelpUITestCase {
    @MainActor
    func testModelsSurvivesABotsPageAndComingBack() {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-demo-reconnects-on-return"]
        app.launch()
        openDefaultModel(in: app)

        openBotDefaultModel(in: app)
        goBack(in: app)
        assertModelsWorks(in: app, "after a bot's Default Model page and back")

        // Leaving the app reconnects; the page is still there when you're back.
        leaveAndComeBack(app)
        assertModelsWorks(in: app, "after leaving the app and coming back")

        // And from a bot's page, which is on top when you leave.
        openBotDefaultModel(in: app)
        leaveAndComeBack(app)
        XCTAssertTrue(app.descendants(matching: .any)["default-models"].firstMatch.waitForExistence(timeout: 5))
        goBack(in: app)
        assertModelsWorks(in: app, "after leaving from a bot's page and going back")
    }

    /// Each bot has its own row, with its model under its name, and opens its own Default Model page.
    @MainActor
    func testEachBotsDefaultModelHasItsOwnRow() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openDefaultModel(in: app)

            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "models.bot."))
            XCTAssertGreaterThanOrEqual(rows.count, 2, "Every bot has a row")
            XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "Mina Shah").evaluate(with: app.buttons["models.bot.travel"]),
                          app.buttons["models.bot.travel"].label)
            evidence("models-\(appearance)", app)

            guard appearance == "light" else { app.terminate(); continue }
            app.buttons["models.bot.travel"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["default-models"].firstMatch.waitForExistence(timeout: 10),
                          "The row opens the bot's Default Model page")
            XCTAssertTrue(app.navigationBars["Default Model"].exists)
            evidence("models-bot-page", app)
            app.terminate()
        }
    }

    /// Settings › Models › Advanced › Refresh model lists.
    @MainActor
    func testRefreshModelCatalogsFromAIProviders() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            settingsRow("settings.default-model", in: app).tap()
            XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 8))
            let refresh = app.buttons["providers.refresh-model-catalogs"]
            let list = app.collectionViews.firstMatch
            for _ in 0..<6 where !(refresh.exists && refresh.isHittable) { list.swipeUp() }
            XCTAssertTrue(refresh.waitForExistence(timeout: 10), "Last, in Advanced")
            evidence("provider-keys-\(appearance)", app)
            refresh.tap()
            // The page says so at its top, above the providers.
            let confirmed = app.descendants(matching: .any)["providers.confirmed"].firstMatch
            for _ in 0..<8 where !confirmed.exists { list.swipeDown() }
            XCTAssertTrue(confirmed.waitForExistence(timeout: 10), "Hermes refreshed the catalogs")
            evidence("provider-keys-refreshed-\(appearance)", app)
            app.terminate()
        }
    }

    /// Settings › Models › Providers: your providers, each with Sign in again and Remove, and one
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
            settingsRow("settings.default-model", in: app).tap()
            XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 8))
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
        settingsRow("settings.default-model", in: app).tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 15))
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
        XCTAssertTrue(firstBotRow(in: app).waitForExistence(timeout: 10),
                      "Models must list the bots", file: file, line: line)
    }

    @MainActor
    private func firstBotRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "models.bot.")).firstMatch
    }

    @MainActor
    private func openBotDefaultModel(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = firstBotRow(in: app)
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { list.swipeUp() }
        XCTAssertTrue(row.isHittable, "Models lists each bot", file: file, line: line)
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["default-models"].firstMatch.waitForExistence(timeout: 8),
                      file: file, line: line)
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
    private func assertModelsWorks(in app: XCUIApplication, _ when: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let reopen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Reopen this feature")).firstMatch
        let row = firstBotRow(in: app)
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where list.exists && !(row.exists && row.isHittable) { list.swipeDown() }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Models must still work \(when)", file: file, line: line)
        XCTAssertFalse(reopen.exists, "No \"Reopen this feature\" \(when)", file: file, line: line)
        XCTAssertTrue(row.isEnabled, "A bot's model can still be changed \(when)", file: file, line: line)
        evidence("models-\(when.replacingOccurrences(of: " ", with: "-"))", app)
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
