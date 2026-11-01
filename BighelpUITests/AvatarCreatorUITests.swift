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
        app.buttons["avatar.creator.face.tool.colors"].firstMatch.tap()
        let swatch = any["avatar.creator.face.palette.Iris"].firstMatch
        for _ in 0..<5 where !(swatch.exists && swatch.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(swatch.exists, "Faces have named palettes")
        swatch.tap()
        XCTAssertTrue(swatch.isSelected)
        let saturation = any["avatar.creator.face-color.saturation"].firstMatch
        for _ in 0..<5 where !(saturation.exists && saturation.isHittable) { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(saturation.exists, "Saturation, down to gray")
        saturation.adjust(toNormalizedSliderPosition: 0)
        XCTAssertTrue(any["avatar.creator.face-color.custom"].firstMatch.exists, "The color wheel")
        save("face-color", app)
    }

    /// The face designer: the play strip plays each state on the face, the tools edit its
    /// shape and size with Undo, and sets and palettes pick a finished face or a color.
    /// BIGHELP_AVATAR_APPEARANCE (light, dark) and BIGHELP_AVATAR_TEXT_SIZE (a content size
    /// category, such as UICTContentSizeCategoryAccessibilityXXL) set how it's drawn.
    @MainActor
    func testFaceDesignerPlaysStatesAndEditsTheShape() throws {
        let environment = ProcessInfo.processInfo.environment
        let appearance = environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light"
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        if let size = environment["BIGHELP_AVATAR_TEXT_SIZE"] {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()
        openRootTab("tab.agents", in: app)
        let create = app.buttons["agents.create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let preview = app.descendants(matching: .any)["agent.editor.avatar-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.tap()
        let any = app.descendants(matching: .any)
        let suffix = environment["BIGHELP_AVATAR_TEXT_SIZE"] == nil ? appearance : "\(appearance)-large-text"
        XCTAssertTrue(app.buttons["avatar.creator.category.hermes"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["avatar.creator.category.hermes"].firstMatch.tap()
        app.buttons["avatar.creator.style.face"].firstMatch.tap()

        // Every state, each named for VoiceOver; one tap plays it on the big face.
        for state in ["idle", "still", "bounce", "listen", "think", "speak", "work", "curious", "love",
                      "celebrate", "sleep", "oops"] {
            XCTAssertTrue(app.buttons["avatar.creator.face.play.\(state)"].firstMatch.exists, state)
        }
        let love = app.buttons["avatar.creator.face.play.love"].firstMatch
        XCTAssertEqual(love.label, "Love")
        reveal(love, in: app)
        love.tap()
        XCTAssertTrue(love.isSelected)
        XCTAssertEqual(any["avatar.creator.preview"].firstMatch.label, "Face preview, Love")
        save("face-play-love-\(suffix)", app)
        let use = app.buttons["avatar.creator.use"].firstMatch
        let undo = app.buttons["avatar.creator.face.undo"].firstMatch
        XCTAssertFalse(undo.isEnabled, "Playing a state changes nothing")

        // Shape: an Organic outline gets bumps, wobble and a mirror, with Undo.
        app.buttons["avatar.creator.face.tool.shape"].firstMatch.tap()
        let organic = app.buttons["avatar.creator.face.organic"].firstMatch
        reveal(organic, in: app)
        organic.tap()
        XCTAssertTrue(undo.isEnabled)
        let mirror = app.switches["avatar.creator.face.mirror"].firstMatch
        reveal(mirror, in: app)
        XCTAssertTrue(mirror.exists, "Organic faces can mirror")
        mirror.switches.firstMatch.tap()
        XCTAssertEqual(mirror.value as? String, "1")
        let wobble = app.sliders["avatar.creator.face.wobble"].firstMatch
        XCTAssertTrue(wobble.exists)
        wobble.adjust(toNormalizedSliderPosition: 0.9)
        save("face-shape-\(suffix)", app)
        undo.tap()
        undo.tap()
        XCTAssertEqual(mirror.value as? String, "0", "Undo steps back through the wobble and the mirror")

        // Size: Taller, then Undo.
        app.buttons["avatar.creator.face.tool.size"].firstMatch.tap()
        let taller = app.buttons["avatar.creator.face.size.taller"].firstMatch
        XCTAssertTrue(taller.waitForExistence(timeout: 3))
        reveal(taller, in: app)
        taller.tap()
        XCTAssertTrue(app.buttons["avatar.creator.face.size.reset"].firstMatch.waitForExistence(timeout: 3))
        save("face-size-\(suffix)", app)
        undo.tap()
        XCTAssertFalse(app.buttons["avatar.creator.face.size.reset"].firstMatch.exists)

        // Sets: a finished face in one tap.
        app.buttons["avatar.creator.face.tool.sets"].firstMatch.tap()
        let lantern = app.buttons["avatar.creator.face.preset.lantern-759"].firstMatch
        XCTAssertTrue(lantern.waitForExistence(timeout: 3))
        reveal(lantern, in: app)
        lantern.tap()
        XCTAssertTrue(lantern.isSelected)
        XCTAssertTrue(use.isEnabled)
        let sleep = app.buttons["avatar.creator.face.play.sleep"].firstMatch
        reveal(sleep, in: app)
        sleep.tap()
        save("face-sets-sleep-\(suffix)", app)

        // Colors: named palettes, the picked one ringed.
        app.buttons["avatar.creator.face.tool.colors"].firstMatch.tap()
        let night = app.buttons["avatar.creator.face.palette.Night"].firstMatch
        XCTAssertTrue(night.waitForExistence(timeout: 3))
        reveal(night, in: app)
        night.tap()
        XCTAssertTrue(night.isSelected)
        XCTAssertFalse(lantern.exists && lantern.isSelected)
        save("face-colors-\(suffix)", app)
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

    /// Large text pushes controls below the fold; scroll the choices until it can be tapped.
    /// The choices can be shorter than two tiles, so a swipe's fling jumps past whole rows:
    /// drag a short way with no fling instead.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        // The choices are the sheet's last scroll view, after the row of categories.
        let scrollViews = app.scrollViews
        let choices = scrollViews.element(boundBy: max(0, scrollViews.count - 1))
        func drag(from: CGFloat, to: CGFloat) {
            choices.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.1, thenDragTo: choices.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        for _ in 0..<14 where !(element.exists && element.isHittable) { drag(from: 0.7, to: 0.3) }
        for _ in 0..<20 where !(element.exists && element.isHittable) { drag(from: 0.3, to: 0.7) }
        XCTAssertTrue(element.isHittable, "\(element) can be reached")
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
