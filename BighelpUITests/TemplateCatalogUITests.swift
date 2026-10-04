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
