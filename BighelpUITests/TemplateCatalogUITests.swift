import XCTest

/// Every template picker by topic: the search row, the topic chips, a section per topic, Sort, and
/// a search that finds nothing. Agents' New agent (its rail and Browse all), Simple Bot mode's New
/// Bot › Templates (My Templates first), and Feed, Ideas and Goals blueprints. Demo data (bundled,
/// offline). BIGHELP_CATALOG_EVIDENCE (TEST_RUNNER_…) saves light and dark shots.
final class TemplateCatalogUITests: BighelpUITestCase {
    @MainActor
    func testBlueprintsByTopicSearchAndSort() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let any = app.descendants(matching: .any)
            for tab in ["tab.feed", "tab.ideas", "tab.goals"] {
                let page = String(tab.dropFirst(4))
                openRootTab(tab, in: app)
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

                if tab == "tab.ideas" {
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
            }
            app.terminate()
        }
    }

    @MainActor
    func testAgentTemplatesByTopic() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            let any = app.descendants(matching: .any)
            openNewAgentTemplates(app)

            // The rail over the editor narrows to a topic.
            let railCoding = app.buttons["agent.editor.templates.category.coding"]
            XCTAssertTrue(railCoding.waitForExistence(timeout: 5), "Topic chips over the rail")
            railCoding.tap()
            XCTAssertTrue(app.buttons["agent.editor.template.forge"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["agent.editor.template.anchor"].exists, "Only Coding's templates")
            save("agent-editor-rail-coding-\(appearance)", app)

            app.buttons["agent.editor.templates.browse"].firstMatch.tap()
            XCTAssertTrue(any["agent.templates.browser"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(any["agent.templates.search"].firstMatch.waitForExistence(timeout: 5), "The search row")
            XCTAssertTrue(any["agent.templates.section.productivity"].firstMatch.exists, "A section per topic")
            XCTAssertTrue(app.buttons["agent.templates.category.all"].isSelected)
            save("agent-templates-\(appearance)", app)

            app.buttons["agent.templates.category.coding"].tap()
            XCTAssertTrue(app.buttons["agent.templates.forge"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["agent.templates.beacon"].exists)
            XCTAssertFalse(any["agent.templates.section.productivity"].firstMatch.exists, "Only Coding")
            save("agent-templates-coding-\(appearance)", app)

            let search = any["agent.templates.search"].firstMatch
            search.tap()
            search.typeText("zzz")
            XCTAssertTrue(any["agent.templates.empty"].firstMatch.waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Nothing in Coding matches \u{201C}zzz\u{201D}."].exists)
            save("agent-templates-empty-\(appearance)", app)
            app.buttons["agent.templates.empty.all"].tap()
            XCTAssertTrue(app.buttons["agent.templates.category.all"].waitForExistence(timeout: 3))
            app.buttons["agent.templates.search.clear"].tap()
            search.typeText("research")
            XCTAssertTrue(app.buttons["agent.templates.lens"].waitForExistence(timeout: 3), "Lens is the research partner")
            XCTAssertTrue(any["agent.templates.section.science"].firstMatch.exists, "…under Science")
            save("agent-templates-search-\(appearance)", app)
            app.buttons["agent.templates.lens"].tap()
            XCTAssertFalse(any["agent.templates.browser"].firstMatch.waitForExistence(timeout: 2), "Picking one closes it")
            XCTAssertEqual(editorRole(app).value as? String, "Research partner")
            app.terminate()
        }
    }

    /// New Bot's Templates: My Templates first and as a chip, then the catalog by topic.
    @MainActor
    func testNewBotTemplatesByTopic() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance]
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

    /// A catalog template with fill-in fields (the demo Field Lead) opens a short form from Browse all:
    /// name first, then its fields. Continue fills the editor's instructions with no `{{` left.
    @MainActor
    func testTemplateFormFillsTheInstructions() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            openNewAgentTemplates(app)
            app.buttons["agent.editor.templates.browse"].firstMatch.tap()
            let search = app.descendants(matching: .any)["agent.templates.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Field")
            let card = app.buttons["agent.templates.field-lead"]
            XCTAssertTrue(card.waitForExistence(timeout: 3), "The demo template with fields")
            card.tap()

            let any = app.descendants(matching: .any)
            XCTAssertTrue(any["agent.template-form"].firstMatch.waitForExistence(timeout: 5), "Its form opens")
            let name = app.textFields["agent.template-form.field.agent_name"]
            let role = app.textFields["agent.template-form.field.agent_role"]
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            XCTAssertTrue(role.exists, "Role follows the name")
            XCTAssertEqual(role.placeholderValue, "Release coordinator", "The example is a hint, not a value")
            let continueButton = app.buttons["agent.template-form.continue"]
            XCTAssertFalse(continueButton.isEnabled, "Required fields are empty")
            save("template-form-empty-\(appearance)", app)

            name.tap()
            name.typeText("Kai")
            XCTAssertFalse(continueButton.isEnabled, "Role is required too")
            role.tap()
            role.typeText("Release coordinator")
            let tone = any["agent.template-form.field.tone"].firstMatch
            let formList = app.collectionViews.firstMatch
            for _ in 0..<3 where !tone.isHittable { formList.swipeUp() }
            tone.tap()
            let warm = app.buttons["Warm"].firstMatch
            XCTAssertTrue(warm.waitForExistence(timeout: 3), "Tone offers its choices")
            warm.tap()
            if appearance == "dark" {
                let context = any["agent.template-form.field.operating_context"].firstMatch
                for _ in 0..<3 where !context.isHittable { formList.swipeUp() }
                context.tap()
                context.typeText("A two-person studio")
            }
            save("template-form-filled-\(appearance)", app)
            XCTAssertTrue(continueButton.isEnabled)
            continueButton.tap()
            XCTAssertTrue(any["agent.template-form"].firstMatch.waitForNonExistence(timeout: 5))

            XCTAssertEqual(app.textFields["agent.editor.name"].value as? String, "Kai")
            XCTAssertEqual(editorRole(app).value as? String, "Release coordinator")
            save("template-form-editor-\(appearance)", app)
            // The editor builds its rows as they scroll into view.
            let instructionsView = app.textViews["agent.editor.instructions"]
            for _ in 0..<5 where !instructionsView.exists { app.swipeUp() }
            let instructions = (instructionsView.value as? String) ?? ""
            XCTAssertTrue(instructions.hasPrefix("# Kai"), instructions)
            XCTAssertTrue(instructions.contains("Role: Release coordinator"))
            XCTAssertTrue(instructions.contains("Tone: Warm."))
            XCTAssertTrue(instructions.contains(appearance == "dark" ? "Operating context: A two-person studio"
                                                : "Operating context: General work for the user."))
            XCTAssertFalse(instructions.contains("{{"), "No placeholder is left")
            XCTAssertFalse(instructions.contains("}}"))
            save("template-form-instructions-\(appearance)", app)
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

    /// Agents › New agent, on its Templates choice.
    @MainActor
    private func openNewAgentTemplates(_ app: XCUIApplication) {
        openRootTab("tab.agents", in: app)
        let create = app.buttons["agents.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let start = app.segmentedControls["agent.editor.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.buttons["Templates"].tap()
        XCTAssertTrue(app.buttons["agent.editor.templates.browse"].firstMatch.waitForExistence(timeout: 5), "Browse all")
    }

    /// The editor's Role field: the form builds rows as they scroll in, and the template rail with
    /// its topic chips can leave Role just below the fold.
    @MainActor
    private func editorRole(_ app: XCUIApplication) -> XCUIElement {
        let role = app.textFields["agent.editor.role"]
        for _ in 0..<3 where !role.exists || !role.isHittable { app.swipeUp() }
        return role
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
