import XCTest

/// The Credential Vault on the demo data: a bot's profile opens its own vault (the wallet, then
/// websites), Add a Website saves a login and a saved card for a new website with one Save, and a
/// saved card goes on another website without being typed again. ☰ opens the same screens.
/// BIGHELP_VAULT_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class CredentialVaultUITests: BighelpUITestCase {
    @MainActor
    func testABotsVaultAddsALoginAndASavedCardForAWebsiteInOneGo() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance]
            app.launch()
            openPrimaryProfile(app)
            app.buttons["simple-bots.profile.tab.info"].tap()
            let row = app.buttons["simple-bots.profile.credential-vault"]
            let advanced = app.buttons["simple-bots.profile.advanced-options"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(advanced.waitForExistence(timeout: 5))
            XCTAssertLessThan(row.frame.minY, advanced.frame.minY, "Credential Vault sits right above Advanced Options")
            for _ in 0..<6 where !row.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(waitUntil { row.label.contains("3 websites") }, row.label)
            save("vault-profile-row-\(appearance)", app)

            row.tap()
            let wallet = app.buttons["vault.wallet.demo-card-1"]
            XCTAssertTrue(wallet.waitForExistence(timeout: 10), "The wallet shows the saved cards")
            XCTAssertTrue(app.buttons["vault.site.shop.example.org"].exists, "Websites are listed under it")
            save("vault-home-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }

            app.buttons["vault.add"].tap()
            let site = app.textFields["vault.add.site"]
            XCTAssertTrue(site.waitForExistence(timeout: 5))
            site.tap()
            // Return closes the keyboard; a tap while it slides up can land on a key.
            site.typeText("store.example.com\n")
            app.buttons["vault.add.part.card"].tap()
            XCTAssertTrue(app.buttons["vault.add.part.login"].isSelected, "Login starts picked")
            XCTAssertTrue(app.buttons["vault.add.part.card"].isSelected)
            save("vault-add-picks", app)
            app.buttons["vault.add.next"].tap()
            save("vault-add-after-next", app)

            let username = app.textFields["vault.username"]
            XCTAssertTrue(username.waitForExistence(timeout: 5))
            username.tap()
            username.typeText("sam@example.com")
            let password = app.secureTextFields["vault.password"]
            password.tap()
            password.typeText("made-up-pass\n")
            let everyday = app.buttons["vault.add.card.saved.demo-card-1"]
            XCTAssertTrue(everyday.waitForExistence(timeout: 5), "Saved cards are offered")
            everyday.tap()
            XCTAssertFalse(app.secureTextFields["vault.card-number"].exists, "A saved card isn't typed again")
            save("vault-add-details", app)
            app.buttons["vault.save"].tap()

            let added = app.buttons["vault.site.store.example.com"]
            XCTAssertTrue(added.waitForExistence(timeout: 10), "One Save adds the website")
            added.tap()
            XCTAssertTrue(app.descendants(matching: .any)["vault.site-page"].waitForExistence(timeout: 5))
            XCTAssertTrue(button(app, containing: "sam@example.com").waitForExistence(timeout: 5))
            XCTAssertTrue(button(app, containing: "Everyday Visa ending 4242").exists, "The saved card is there too")
            save("vault-site-page", app)
            app.terminate()
        }
    }

    @MainActor
    func testTheMenuOpensTheSameVaultAndACardGoesOnAnotherWebsite() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "light"]
        app.launch()
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        let vault = app.buttons["menu.vault"]
        for _ in 0..<6 where !(vault.exists && vault.isHittable) { app.swipeUp() }
        vault.tap()

        let unlinked = app.buttons["vault.wallet.demo-card-3"]
        XCTAssertTrue(unlinked.waitForExistence(timeout: 10))
        XCTAssertTrue(unlinked.label.contains("No website yet"), unlinked.label)
        unlinked.tap()
        XCTAssertTrue(app.descendants(matching: .any)["vault.item-page"].waitForExistence(timeout: 5))
        app.buttons["vault.item.use-on-site"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("air.example.com")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["air.example.com"].waitForExistence(timeout: 10), "The card is used there now")
        XCTAssertFalse(app.staticTexts["Not on a website yet"].exists)
        save("vault-card-page", app)
    }

    /// A real host: a saved card goes on another website, and Add a Website takes it for a new one,
    /// both copied by the plugin's vault/link. Set BIGHELP_VAULT_HOST (TEST_RUNNER_…) to an open host
    /// whose default agent has a saved card named BIGHELP_VAULT_CARD on a website, with a plugin that
    /// has native-vault-link-v1. Uninstall bighelp from the simulator first.
    @MainActor
    func testARealHostCopiesASavedCardWithoutTypingIt() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["BIGHELP_VAULT_HOST"], let card = environment["BIGHELP_VAULT_CARD"] else {
            throw XCTSkip("Set BIGHELP_VAULT_HOST and BIGHELP_VAULT_CARD for a scratch Hermes host")
        }
        let app = makeApp()
        app.launch()
        try onboardOpenHost(app, address: address)
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 30))
        menu.tap()
        let vault = app.buttons["menu.vault"]
        for _ in 0..<6 where !(vault.exists && vault.isHittable) { app.swipeUp() }
        vault.tap()

        let tile = button(app, containing: card)
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "The host's saved card is in the wallet")
        save("vault-real-host-home", app)
        tile.tap()
        app.buttons["vault.item.use-on-site"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("air.example.com")
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["air.example.com"].waitForExistence(timeout: 20), "The host copied it there")
        XCTAssertFalse(app.descendants(matching: .any)["vault.message"].exists)
        save("vault-real-host-card", app)
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["vault.add"].tap()
        let site = app.textFields["vault.add.site"]
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        site.tap()
        site.typeText("pay.example.com\n")
        app.buttons["vault.add.part.login"].tap()
        app.buttons["vault.add.part.card"].tap()
        app.buttons["vault.add.next"].tap()
        let picked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "vault.add.card.saved.")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5), "The saved card is offered")
        XCTAssertTrue(picked.isSelected, "and picked to start with")
        app.buttons["vault.save"].tap()
        XCTAssertTrue(app.buttons["vault.site.pay.example.com"].waitForExistence(timeout: 20), "One Save added the website")
        save("vault-real-host-added", app)
    }

    @MainActor
    private func openPrimaryProfile(_ app: XCUIApplication) {
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.primary"].tap()
        let identity = app.buttons["chat.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        let profile = app.descendants(matching: .any)["simple-bots.profile"]
        // A tap while the chat is still sliding in can miss; one more is enough.
        identity.tap()
        if !profile.waitForExistence(timeout: 5) { identity.tap() }
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
    }

    private func button(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_VAULT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
