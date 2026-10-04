import XCTest

/// ☰ › Secure credential vault on the demo data: items show their name and sites, a card with no
/// site says the agent can't use it yet, and tapping one opens it to rename and relink.
/// BIGHELP_VAULT_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class CredentialVaultUITests: BighelpUITestCase {
    @MainActor
    func testItemsShowTheirNamesAndSitesAndOpenToEdit() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 15))
            menu.tap()
            let vault = app.buttons["menu.vault"]
            for _ in 0..<6 where !(vault.exists && vault.isHittable) { app.swipeUp() }
            vault.tap()
            let card = app.descendants(matching: .any)["vault.item.demo-card-1"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(card.label.contains("Everyday Visa ending 4242"), card.label)
            XCTAssertTrue(card.label.contains("shop.example.org, parts.example.net"), card.label)
            let unlinked = app.descendants(matching: .any)["vault.item.demo-card-3"]
            XCTAssertTrue(unlinked.label.contains("can't use it yet"), unlinked.label)
            save("vault-list-\(appearance)", app)
            guard appearance == "light" else { app.terminate(); continue }

            card.tap()
            let name = app.textFields["vault.label"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            XCTAssertEqual(name.value as? String, "Everyday Visa")
            XCTAssertEqual(app.textFields["vault.site"].value as? String, "shop.example.org")
            XCTAssertEqual(app.textFields["vault.site.1"].value as? String, "parts.example.net")
            save("vault-edit-card", app)
            app.terminate()
        }
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
