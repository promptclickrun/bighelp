import XCTest

/// Plugins and the Skills Hub as storefronts, on the demo catalogs (`DemoCapabilityCatalogHost`):
/// a hero and shelves on each home, a card opening its page with the one Install or Add, and
/// chips that stay whole inside the page's margins at the largest text size.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class CatalogStorefrontUITests: BighelpUITestCase {
    @MainActor
    func testStorefrontsOpenTheirPagesInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)

            openHermesTool("plugins", in: app)
            let hero = app.buttons["plugins.hero"]
            XCTAssertTrue(hero.waitForExistence(timeout: 10), "Plugins opens on its featured plugin")
            XCTAssertTrue(app.descendants(matching: .any)["plugins.shelf.trusted"].exists,
                          "Official and verified plugins have their own shelf")
            XCTAssertTrue(app.descendants(matching: .any)["plugins.shelf.memory"].exists, "Each topic has a shelf")
            assertWholeCards("plugins.card.", in: app)
            evidence("plugins-home-\(appearance)", app)

            let seeAll = app.buttons["plugins.seeAll.memory"]
            XCTAssertTrue(seeAll.exists)
            seeAll.tap()
            XCTAssertTrue(app.descendants(matching: .any)["plugins.category"].waitForExistence(timeout: 5))
            evidence("plugins-category-\(appearance)", app)

            let card = app.buttons["plugins.card.memory-wiki"]
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            card.tap()
            let install = app.buttons["plugin.install"]
            XCTAssertTrue(install.waitForExistence(timeout: 5), "A card opens its page with Install ready")
            XCTAssertTrue(install.isEnabled)
            XCTAssertTrue(app.descendants(matching: .any)["plugin.trust"].exists,
                          "What it adds, the keys it needs and the pinned commit show with Install")
            goBack(in: app)
            goBack(in: app)

            hero.tap()
            XCTAssertTrue(app.buttons["plugin.install"].waitForExistence(timeout: 5))
            evidence("plugin-page-\(appearance)", app)
            // Install asks once more, naming what it adds, from where and at which commit.
            app.buttons["plugin.install"].tap()
            let confirm = app.buttons["Install and turn on"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Install confirms before anything changes")
            let cancel = app.buttons["Cancel"]
            if cancel.exists { cancel.tap() } else { app.tap() }

            app.terminate()
            let skillsApp = launch(appearance: appearance)
            openHermesTool("skills", in: skillsApp)
            XCTAssertTrue(skillsApp.buttons["skills.hero"].waitForExistence(timeout: 10),
                          "The Skills Hub opens on Hermes' official collection")
            XCTAssertTrue(skillsApp.descendants(matching: .any)["skills.shelf.official"].exists)
            XCTAssertTrue(skillsApp.buttons["skills.mine"].exists, "The agent's own skills are one tap away")
            assertWholeCards("skills.tile.", in: skillsApp)
            evidence("skills-home-\(appearance)", skillsApp)

            let tile = skillsApp.buttons["skills.tile.official/finance/three-statement-model"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            tile.tap()
            XCTAssertTrue(skillsApp.descendants(matching: .any)["skill.verdict"].waitForExistence(timeout: 10),
                          "Hermes' scan shows before Add")
            let add = skillsApp.buttons["skill.add"]
            XCTAssertTrue(add.exists && add.isEnabled, "A skill the scan allows can be added in one tap")
            evidence("skill-page-\(appearance)", skillsApp)
            skillsApp.terminate()
        }
    }

    /// A skill Hermes' scan blocks can't be added.
    @MainActor
    func testBlockedSkillCannotBeAdded() {
        let app = launch(appearance: "light")
        openHermesTool("skills", in: app)
        let search = app.descendants(matching: .any)["skills.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("shell\n")
        let tile = app.buttons["skills.tile.clawhub/shell-anything"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Return searches the hubs")
        tile.tap()
        XCTAssertTrue(app.descendants(matching: .any)["skill.verdict"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["skill.add"].isEnabled, "A blocking scan leaves Add off")
    }

    /// Chips and filters keep every label whole inside the page at the largest text size.
    @MainActor
    func testChipsStayInsideThePageAtLargestText() {
        let app = launch(appearance: "light",
                         extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        openHermesTool("plugins", in: app)
        XCTAssertTrue(app.buttons["plugins.hero"].waitForExistence(timeout: 10))
        assertWholeCards("plugins.card.", in: app)
        evidence("plugins-home-xxxl", app)
        app.buttons["plugins.hero"].tap()
        let badges = app.descendants(matching: .any)["plugin.page"]
        XCTAssertTrue(badges.waitForExistence(timeout: 5))
        evidence("plugin-page-xxxl", app)
        app.terminate()

        let skills = launch(appearance: "light",
                            extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        openHermesTool("skills", in: skills)
        let search = skills.descendants(matching: .any)["skills.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("plan")
        let chips = skills.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "skills.source."))
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 5), "Hub chips show while searching")
        let window = skills.windows.firstMatch.frame
        for chip in chips.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(chip.frame.minX, window.minX + 15, "\(chip.label) starts inside the margin")
            XCTAssertLessThanOrEqual(chip.frame.maxX, window.maxX - 15, "\(chip.label) ends inside the margin")
        }
        evidence("skills-search-xxxl", skills)
    }

    /// Every shelf card on screen is whole, inside the page margins: none is cut at the edge.
    @MainActor
    private func assertWholeCards(_ prefix: String, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex
        XCTAssertFalse(cards.isEmpty, "Shelves show cards", file: file, line: line)
        // A card starting at the screen's edge is off screen, not cut.
        for card in cards where card.frame.minX < window.maxX - 1 && card.frame.maxX > window.minX + 1
            && card.frame.maxY < window.maxY {
            XCTAssertGreaterThanOrEqual(card.frame.minX, window.minX + 15,
                                        "\(card.identifier) starts inside the page", file: file, line: line)
            XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX - 15,
                                     "\(card.identifier) ends inside the page", file: file, line: line)
        }
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            + extra
        app.launch()
        return app
    }

    @MainActor
    private func goBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
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
