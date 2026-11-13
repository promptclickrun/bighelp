import XCTest

/// Every template picker by topic: the search row, the topic chips, a section per topic, Sort, and
/// a search that finds nothing. Bots' New Bot › Templates (My Templates first), and Feed, Ideas and
/// Goals blueprints on a bot's board (Today › See all, one bot). Demo data (bundled,
/// offline). BIGHELP_CATALOG_EVIDENCE (TEST_RUNNER_…) saves light and dark shots.
final class TemplateCatalogUITests: BighelpUITestCase {
    @MainActor
    func testBlueprintsByTopicSearchAndSort() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let any = app.descendants(matching: .any)
            for page in ["feed", "ideas", "goals"] {
                // Today › See all, then one bot's board: Blueprints sits by its title.
                openTodayBoard(page, in: app)
                let bot = app.buttons["today.board-page.chip.finance"].firstMatch
                XCTAssertTrue(bot.waitForExistence(timeout: 10), "\(page) lists the bots")
                bot.tap()
                let open = app.buttons["board.blueprints"].firstMatch
                XCTAssertTrue(open.waitForExistence(timeout: 10), "Blueprints on \(page)")
                open.tap()
                XCTAssertTrue(any["board.blueprints.sheet"].firstMatch.waitForExistence(timeout: 5))
                XCTAssertTrue(any["board.blueprints.search"].firstMatch.waitForExistence(timeout: 5), "The search row")
                XCTAssertTrue(any["board.blueprints.section.productivity"].firstMatch.exists, "A section per topic")
                XCTAssertTrue(app.buttons["board.blueprints.category.all"].isSelected, "All to start")
                save("blueprints-\(page)-\(appearance)", app)

                let marketing = app.buttons["board.blueprints.category.marketing"]
                XCTAssertTrue(marketing.exists, "A chip per topic")
                marketing.tap()
                XCTAssertTrue(any["board.blueprints.section.marketing"].firstMatch.waitForExistence(timeout: 3))
                XCTAssertFalse(any["board.blueprints.section.productivity"].firstMatch.exists, "Only that topic")
                XCTAssertTrue(marketing.isSelected)
                save("blueprints-\(page)-marketing-\(appearance)", app)

                if page == "ideas" {
                    let search = any["board.blueprints.search"].firstMatch
                    search.tap()
                    search.typeText("zzz")
                    let empty = any["board.blueprints.empty"].firstMatch
                    XCTAssertTrue(empty.waitForExistence(timeout: 3), "A search with no results says so")
                    XCTAssertTrue(app.staticTexts["Nothing in Marketing matches \u{201C}zzz\u{201D}."].exists)
                    save("blueprints-ideas-empty-\(appearance)", app)
                    app.buttons["board.blueprints.empty.all"].tap()
                    XCTAssertTrue(app.staticTexts["Nothing matches \u{201C}zzz\u{201D}."].waitForExistence(timeout: 3),
                                  "Search all looks in every topic")
                    XCTAssertTrue(app.buttons["board.blueprints.category.all"].isSelected)

                    app.buttons["board.blueprints.search.clear"].tap()
                    search.typeText("calendar")
                    XCTAssertTrue(app.buttons["board.blueprint.ideas-productivity-2"].waitForExistence(timeout: 3))
                    XCTAssertTrue(any["board.blueprints.section.productivity"].firstMatch.exists,
                                  "Results stay under their topic")
                    XCTAssertFalse(any["board.blueprints.section.marketing"].firstMatch.exists)
                    save("blueprints-ideas-search-\(appearance)", app)
                    app.buttons["board.blueprints.search.clear"].tap()

                    app.buttons["board.blueprints.sort"].tap()
                    let newest = app.buttons["Newest"].firstMatch
                    XCTAssertTrue(newest.waitForExistence(timeout: 3), "Sort offers Newest")
                    newest.tap()
                    XCTAssertTrue(any["board.blueprints.section.ranked"].firstMatch.waitForExistence(timeout: 3),
                                  "Newest is one ranked list")
                    save("blueprints-ideas-newest-\(appearance)", app)
                }
                app.buttons["board.blueprints.done"].tap()
                XCTAssertTrue(any["board.blueprints.sheet"].firstMatch.waitForNonExistence(timeout: 5))
                app.buttons["today.board-page.back"].firstMatch.tap()
            }
            app.terminate()
        }
    }

    /// New Bot's Templates: My Templates first and as a chip, then the catalog by topic.
    @MainActor
    func testNewBotTemplatesByTopic() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.home.landing", "bots", "-loopdy.demo.appearance", appearance]
            app.launch()
            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["simple-bots.home"].waitForExistence(timeout: 15))
            app.buttons["simple-bots.new"].tap()
            app.buttons["New Bot"].tap()
            let templates = app.buttons["simple-bots.create.templates"]
            XCTAssertTrue(templates.waitForExistence(timeout: 5))
            templates.tap()
            XCTAssertTrue(any["agent.templates.mine"].firstMatch.waitForExistence(timeout: 10), "My Templates first")
            let mineChip = app.buttons["agent.templates.category.mine"]
            XCTAssertTrue(mineChip.exists, "…with its own chip")
            XCTAssertTrue(any["agent.templates.section.productivity"].firstMatch.exists, "Then the catalog by topic")
            save("new-bot-templates-\(appearance)", app)

            app.buttons["agent.templates.category.creative"].tap()
            XCTAssertTrue(app.buttons["agent.templates.muse"].waitForExistence(timeout: 3))
            XCTAssertFalse(any["agent.templates.mine"].firstMatch.exists, "A topic shows only its templates")
            save("new-bot-templates-creative-\(appearance)", app)

            mineChip.tap()
            XCTAssertTrue(any["agent.templates.mine"].firstMatch.waitForExistence(timeout: 3))
            XCTAssertFalse(any["agent.templates.section.creative"].firstMatch.exists, "My Templates alone")
            save("new-bot-templates-mine-\(appearance)", app)

            app.buttons["agent.templates.category.all"].tap()
            let search = any["agent.templates.search"].firstMatch
            search.tap()
            search.typeText("story")
            XCTAssertTrue(app.buttons["agent.templates.fable"].waitForExistence(timeout: 3))
            save("new-bot-templates-search-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func launch(_ appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CATALOG_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
