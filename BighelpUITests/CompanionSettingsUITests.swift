import XCTest

/// Settings › Companion pet: each agent's pet is its own avatar, so the page holds only Show pet
/// companion, Pet size and Adventurous Pet. No app default character, no colors, no per-agent picks.
/// BIGHELP_UI_EVIDENCE=<folder> saves the screenshots there.
final class CompanionSettingsUITests: BighelpUITestCase {
    @MainActor
    func testThePetPageHasOnlyItsThreeControls() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            // The pet is a row in Appearance, under Chat layout and App layout.
            settingsRow("settings.themes", in: app).tap()
            let entry = app.buttons["companion-settings-entry"].firstMatch
            for _ in 0..<8 where !(entry.exists && entry.isHittable) { app.swipeUp() }
            entry.tap()

            let page = app.descendants(matching: .any)["companion.settings"]
            XCTAssertTrue(page.waitForExistence(timeout: 10))
            XCTAssertTrue(app.switches["companion.enabled"].exists, "Show pet companion")
            XCTAssertTrue(app.sliders["companion.size"].exists, "Pet size")
            XCTAssertTrue(app.switches["companion.adventurous"].exists, "Adventurous Pet")

            let others = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'companion.' AND NOT (identifier IN %@)",
                ["companion.settings", "companion.enabled", "companion.size", "companion.adventurous"]))
            XCTAssertEqual(others.count, 0, "Nothing else: \(others.allElementsBoundByIndex.map(\.identifier))")
            XCTAssertEqual(app.colorWells.count, 0, "No color pickers")
            for retired in ["App default", "Character", "Match app theme", "Custom color", "Use app default for all agents",
                            "Reset Size"] {
                XCTAssertFalse(app.staticTexts[retired].exists || app.buttons[retired].exists, retired)
            }
            evidence("companion-settings-\(appearance)", app)

            let toggle = app.switches["companion.enabled"]
            let before = toggle.value as? String
            toggle.switches.firstMatch.tap()
            XCTAssertNotEqual(toggle.value as? String, before, "The switch still works")
            app.terminate()
        }
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
