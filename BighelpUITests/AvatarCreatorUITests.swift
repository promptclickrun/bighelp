import XCTest

/// Agents › New agent › avatar: bighelp's catalog characters, hermes's Faces and Shapes (with colors),
/// petdex and other, and Randomize in each. BIGHELP_AVATAR_EVIDENCE (TEST_RUNNER_…) saves the screenshots.
final class AvatarCreatorUITests: BighelpUITestCase {
    @MainActor
    func testFacesHaveColorsLikeShapes() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openRootTab("tab.agents", in: app)
        let create = app.buttons["agents.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let preview = app.descendants(matching: .any)["agent.editor.avatar-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["avatar.creator.category.bighelp"].firstMatch.waitForExistence(timeout: 10))
        let biggie = any["avatar.creator.catalog.bighelp-biggie"].firstMatch
        XCTAssertTrue(biggie.waitForExistence(timeout: 5), "bighelp's characters, from the shipped catalog")
        biggie.tap()
        XCTAssertEqual(any["avatar.creator.name"].firstMatch.label, "Biggie")
        save("bighelp", app)
        any["avatar.creator.shuffle"].firstMatch.tap()
        XCTAssertNotEqual(any["avatar.creator.name"].firstMatch.label, "Biggie", "Randomize picks another character")
        save("bighelp-randomized", app)
        any["avatar.creator.category.other"].firstMatch.tap()
        XCTAssertTrue(any["avatar.creator.catalog.empty"].firstMatch.waitForExistence(timeout: 3))
        save("other", app)
        any["avatar.creator.category.hermes"].firstMatch.tap()
        XCTAssertTrue(any["avatar.creator.style.shapes"].firstMatch.waitForExistence(timeout: 3), "hermes has Faces and Shapes")
        any["avatar.creator.style.shapes"].firstMatch.tap()
        let shapeName = any["avatar.creator.name"].firstMatch.label
        any["avatar.creator.shuffle"].firstMatch.tap()
        XCTAssertNotEqual(any["avatar.creator.name"].firstMatch.label, shapeName, "Randomize picks another shape")
        save("hermes-shapes", app)
        any["avatar.creator.style.face"].firstMatch.tap()
        let swatch = any["avatar.creator.face-color.3"].firstMatch
        for _ in 0..<5 where !(swatch.exists && swatch.isHittable) { app.swipeUp() }
        XCTAssertTrue(swatch.exists, "Face has colors like Shapes")
        swatch.tap()
        let saturation = any["avatar.creator.face-color.saturation"].firstMatch
        for _ in 0..<3 where !(saturation.exists && saturation.isHittable) { app.swipeUp() }
        XCTAssertTrue(saturation.exists, "Saturation, down to gray")
        saturation.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(any["avatar.creator.face-color.custom"].firstMatch.exists, "The color wheel")
        save("face-color", app)
    }

    /// Editing an agent: the picker opens on the avatar it has now, never a random one, and
    /// Use avatar stays off until something changes, so a quick tap can't replace it.
    @MainActor
    func testExistingAgentsOpenOnTheirOwnAvatar() throws {
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light"
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-test-agent-companion", "finance:bighelp-biggie", "-test-agent-pet", "home:pip"]
        app.launch()
        let any = app.descendants(matching: .any)
        let use = app.buttons["avatar.creator.use"].firstMatch

        // A character keeps its character, colors and moves.
        openAvatarPicker(of: "finance", in: app)
        XCTAssertEqual(any["avatar.creator.name"].firstMatch.label, "Biggie", "Opens on the agent's own character")
        XCTAssertTrue(app.buttons["avatar.creator.category.bighelp"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["avatar.creator.catalog.bighelp-biggie"].firstMatch.isSelected)
        XCTAssertFalse(use.isEnabled, "Nothing to use until something changes")
        save("current-character-\(appearance)", app)
        app.buttons["avatar.creator.tab.color"].firstMatch.tap()
        let cobalt = any["avatar.creator.color.cobalt"].firstMatch
        // The choices scroll under the stage, so drag in their part of the sheet.
        for _ in 0..<5 where !(cobalt.exists && cobalt.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
        }
        save("current-character-color-\(appearance)", app)
        XCTAssertTrue(cobalt.isSelected, "Its own color")
        let moves = app.buttons["avatar.creator.tab.moves"].firstMatch
        for _ in 0..<5 where !moves.isHittable { app.scrollViews.firstMatch.swipeDown() }
        moves.tap()
        let bouncy = app.buttons["avatar.creator.move.bouncy"].firstMatch
        XCTAssertTrue(bouncy.waitForExistence(timeout: 5))
        XCTAssertTrue(bouncy.isSelected, "Its own moves")
        XCTAssertFalse(use.isEnabled, "Looking at a tab changes nothing")
        app.buttons["avatar.creator.move.dancer"].firstMatch.tap()
        XCTAssertTrue(use.isEnabled, "A change can be used")
        closePickerAndEditor(app)

        // A petdex pet opens in petdex, with that pet picked.
        openAvatarPicker(of: "home", in: app)
        XCTAssertTrue(app.buttons["avatar.creator.category.petdex"].firstMatch.isSelected)
        let pip = app.buttons["avatar.creator.pet.pip"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: pip)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 10), .completed, "The agent's pet is picked")
        XCTAssertEqual(any["avatar.creator.name"].firstMatch.label, "Pip")
        XCTAssertFalse(use.isEnabled)
        save("current-pet-\(appearance)", app)
        closePickerAndEditor(app)

        // No avatar yet: the Photo page with the agent's initials, not a surprise character.
        openAvatarPicker(of: "travel", in: app)
        XCTAssertTrue(app.buttons["avatar.creator.category.photo"].firstMatch.isSelected)
        XCTAssertFalse(use.isEnabled)
        save("current-none-\(appearance)", app)

        // A Hermes shape, once saved, is where the picker opens next time.
        app.buttons["avatar.creator.category.hermes"].firstMatch.tap()
        app.buttons["avatar.creator.style.shapes"].firstMatch.tap()
        let hexagon = app.buttons["avatar.creator.shape.hexagon"].firstMatch
        XCTAssertTrue(hexagon.waitForExistence(timeout: 5))
        hexagon.tap()
        XCTAssertTrue(use.isEnabled)
        use.tap()
        let saveAgent = app.buttons["agent.editor.save"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: saveAgent)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        saveAgent.tap()
        XCTAssertTrue(saveAgent.waitForNonExistence(timeout: 10))
        openAvatarPicker(of: "travel", in: app)
        XCTAssertTrue(app.buttons["avatar.creator.style.shapes"].firstMatch.isSelected)
        XCTAssertTrue(hexagon.isSelected, "Opens on the saved shape")
        XCTAssertFalse(use.isEnabled)
        save("current-shape-\(appearance)", app)
    }

    @MainActor
    private func openAvatarPicker(of agentID: String, in app: XCUIApplication) {
        openAgents(in: app)
        let more = app.buttons["agent.\(agentID).more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        for _ in 0..<6 where !more.isHittable { app.swipeUp() }
        // The last row's button sits partly under the floating New chat button: tap its top.
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let edit = app.buttons["agent.\(agentID).edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let design = app.buttons["agent.editor.design-avatar"].firstMatch
        XCTAssertTrue(design.waitForExistence(timeout: 10))
        design.tap()
        XCTAssertTrue(app.buttons["avatar.creator.use"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    private func closePickerAndEditor(_ app: XCUIApplication) {
        app.buttons["avatar.creator.cancel"].firstMatch.tap()
        let cancel = app.buttons["agent.editor.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5), "Cancel left nothing to discard")
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
