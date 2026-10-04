import XCTest

/// Blueprints and agent templates: search, For you / Newest / Most used, bighelp only, and
/// categories. Demo data (bundled, offline). BIGHELP_CATALOG_EVIDENCE (TEST_RUNNER_…) saves shots.
final class TemplateCatalogUITests: BighelpUITestCase {
    @MainActor
    func testBlueprintsSearchSortAndFilter() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openRootTab("tab.ideas", in: app)
        let open = app.buttons.matching(NSPredicate(format: "label == %@", "Blueprints")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["board.blueprints.sheet"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(any["board.blueprints.order"].firstMatch.exists)
        XCTAssertTrue(any["board.blueprints.official"].firstMatch.exists, "bighelp only")
        save("blueprints", app)

        any["board.blueprints.category.marketing"].firstMatch.tap()
        save("blueprints-marketing", app)
        any["board.blueprints.category.all"].firstMatch.tap()
        app.buttons["Most used"].firstMatch.tap()
        save("blueprints-most-used", app)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "A search bar")
        search.tap()
        search.typeText("calendar")
        save("blueprints-search", app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'calendar'")).firstMatch
            .waitForExistence(timeout: 3) || any.matching(NSPredicate(format: "label CONTAINS[c] 'calendar'")).firstMatch.exists)
    }

    @MainActor
    func testAgentTemplatesBrowseAll() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        openRootTab("tab.agents", in: app)
        let create = app.buttons["agents.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let start = app.segmentedControls["agent.editor.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.buttons["Templates"].tap()
        let browse = app.buttons["agent.editor.templates.browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 5), "Browse all")
        browse.tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["agent.templates.browser"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(any["agent.templates.order"].firstMatch.exists)
        XCTAssertTrue(any["agent.templates.official"].firstMatch.exists)
        save("agent-templates", app)
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("research")
        XCTAssertTrue(app.buttons["agent.templates.lens"].waitForExistence(timeout: 3), "Lens is the research partner")
        save("agent-templates-search", app)
        app.buttons["agent.templates.lens"].tap()
        XCTAssertFalse(any["agent.templates.browser"].firstMatch.waitForExistence(timeout: 2), "Picking one closes it")
    }

    /// A catalog template with fill-in fields (the demo Field Lead) opens a short form from Browse all:
    /// name first, then its fields. Continue fills the editor's instructions with no `{{` left.
    @MainActor
    func testTemplateFormFillsTheInstructions() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            openRootTab("tab.agents", in: app)
            let create = app.buttons["agents.create"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 10))
            create.tap()
            let start = app.segmentedControls["agent.editor.start"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 10))
            start.buttons["Templates"].tap()
            app.buttons["agent.editor.templates.browse"].firstMatch.tap()
            let search = app.searchFields.firstMatch
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
            XCTAssertEqual(app.textFields["agent.editor.role"].value as? String, "Release coordinator")
            let instructions = (app.textViews["agent.editor.instructions"].value as? String) ?? ""
            XCTAssertTrue(instructions.hasPrefix("# Kai"), instructions)
            XCTAssertTrue(instructions.contains("Role: Release coordinator"))
            XCTAssertTrue(instructions.contains("Tone: Warm."))
            XCTAssertTrue(instructions.contains(appearance == "dark" ? "Operating context: A two-person studio"
                                                : "Operating context: General work for the user."))
            XCTAssertFalse(instructions.contains("{{"), "No placeholder is left")
            XCTAssertFalse(instructions.contains("}}"))
            save("template-form-editor-\(appearance)", app)
            app.swipeUp()
            save("template-form-instructions-\(appearance)", app)
            app.terminate()
        }
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
