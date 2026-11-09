import XCTest

/// Agents › an agent › Edit avatar: the chooser (Bot Studio, PetDex or a photo), Bot Studio's
/// drawer with every tab, Undo and Surprise me, and PetDex with only pets.
/// BIGHELP_AVATAR_EVIDENCE (TEST_RUNNER_…) saves the screenshots; BIGHELP_AVATAR_APPEARANCE
/// (light, dark) sets how they're drawn.
final class AvatarCreatorUITests: BighelpUITestCase {
    /// An agent's catalog character opens in Bot Studio as its redrawn self; each tab changes the
    /// avatar, and a saved avatar is where the studio opens next time.
    @MainActor
    func testBotStudioEditsEveryPartAndOpensOnTheSavedAvatar() throws {
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light"
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-test-agent-companion", "finance:bighelp-biggie"]
        app.launch()
        let any = app.descendants(matching: .any)

        openChooser(of: "finance", in: app)
        XCTAssertTrue(any["avatar.chooser.petdex"].firstMatch.exists, "PetDex is the other choice")
        XCTAssertTrue(any["avatar.chooser.photo"].firstMatch.exists, "A photo still works")
        save("chooser-\(appearance)", app)
        any["avatar.chooser.studio"].firstMatch.tap()

        let stage = any["bot.studio.stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        XCTAssertTrue(stage.label.hasSuffix("Biggie"), "Opens on the agent's own character, redrawn: \(stage.label)")
        save("studio-body-\(appearance)", app)

        app.buttons["bot.studio.chip.shapes"].firstMatch.tap()
        let peak = app.buttons["bot.studio.choice.Peak"].firstMatch
        XCTAssertTrue(peak.waitForExistence(timeout: 5))
        peak.tap()
        XCTAssertTrue(stage.label.hasSuffix("Peak"))

        app.buttons["bot.studio.tab.eyes"].firstMatch.tap()
        app.buttons["bot.studio.choice.Wide"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.choice.Wide"].firstMatch.isSelected)
        save("studio-eyes-\(appearance)", app)

        app.buttons["bot.studio.tab.color"].firstMatch.tap()
        app.buttons["bot.studio.choice.Moss"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.choice.Moss"].firstMatch.isSelected)
        save("studio-color-\(appearance)", app)

        app.buttons["bot.studio.tab.shape"].firstMatch.tap()
        let lean = app.sliders["bot.studio.slider.lean"].firstMatch
        XCTAssertTrue(lean.waitForExistence(timeout: 5))
        lean.adjust(toNormalizedSliderPosition: 0.8)
        save("studio-shape-\(appearance)", app)

        app.buttons["bot.studio.tab.moves"].firstMatch.tap()
        app.buttons["bot.studio.chip.lookAround"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.chip.lookAround"].firstMatch.isSelected)
        app.buttons["bot.studio.chip.think"].firstMatch.tap()
        save("studio-moves-\(appearance)", app)

        // Surprise me picks something new; Undo brings back what it replaced.
        app.buttons["bot.studio.surprise"].firstMatch.tap()
        app.buttons["bot.studio.undo"].firstMatch.tap()
        XCTAssertTrue(stage.label.hasSuffix("Peak"), "Undo takes back the surprise")

        app.buttons["bot.studio.save"].firstMatch.tap()
        let saveAgent = app.buttons["agent.editor.save"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: saveAgent)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        save("editor-with-studio-avatar-\(appearance)", app)
        saveAgent.tap()
        XCTAssertTrue(saveAgent.waitForNonExistence(timeout: 10))

        openChooser(of: "finance", in: app)
        any["avatar.chooser.studio"].firstMatch.tap()
        XCTAssertTrue(stage.waitForExistence(timeout: 10))
        XCTAssertTrue(stage.label.hasSuffix("Peak"), "Opens on the saved avatar: \(stage.label)")
        app.buttons["bot.studio.tab.eyes"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.choice.Wide"].firstMatch.isSelected, "With its own eyes")

        // Another body starts as it comes: its own eyes and no move, nothing from the last one.
        app.buttons["bot.studio.tab.body"].firstMatch.tap()
        app.buttons["bot.studio.choice.Ball"].firstMatch.tap()
        XCTAssertTrue(stage.label.hasSuffix("Ball"))
        app.buttons["bot.studio.tab.eyes"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.choice.Classic"].firstMatch.isSelected, "Not the last body's eyes")
        app.buttons["bot.studio.tab.moves"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.chip.calm"].firstMatch.isSelected, "No move until one is picked")
        app.buttons["bot.studio.surprise"].firstMatch.tap()
        XCTAssertTrue(app.buttons["bot.studio.chip.calm"].firstMatch.isSelected, "Surprise me adds no move")
        save("studio-new-body-\(appearance)", app)
    }

    /// A swipe up on the row of bodies opens all of them in a grid, by set, with the avatar still in
    /// view; a pick there changes it. The handle shows one row again, even with the grid scrolled,
    /// and the row still scrolls sideways.
    @MainActor
    func testSwipingUpOnTheBodiesOpensEveryBody() throws {
        let appearance = ProcessInfo.processInfo.environment["BIGHELP_AVATAR_APPEARANCE"] ?? "light"
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-test-agent-companion", "finance:bighelp-biggie"]
        app.launch()
        let any = app.descendants(matching: .any)
        openChooser(of: "finance", in: app)
        any["avatar.chooser.studio"].firstMatch.tap()
        let stage = any["bot.studio.stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 10))

        let gallery = any["bot.studio.gallery"].firstMatch
        let peak = app.buttons["bot.studio.choice.Peak"].firstMatch
        XCTAssertTrue(peak.waitForExistence(timeout: 5) && peak.isHittable)
        drag(peak, by: -220)
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "A swipe up opens every body")
        XCTAssertTrue(stage.isHittable, "The avatar stays in view")
        save("studio-gallery-\(appearance)", app)

        let bow = app.buttons["bot.studio.choice.Bow"].firstMatch
        for _ in 0..<12 where !(bow.exists && bow.isHittable) { gallery.swipeUp() }
        bow.tap()
        XCTAssertTrue(stage.label.hasSuffix("Bow"), "A pick in the gallery: \(stage.label)")
        XCTAssertTrue(gallery.exists, "The gallery stays open for the next pick")
        save("studio-gallery-picked-\(appearance)", app)

        let handle = app.buttons["bot.studio.gallery.toggle"].firstMatch
        handle.tap()
        XCTAssertTrue(gallery.waitForNonExistence(timeout: 5), "The handle shows one row again")

        XCTAssertTrue(peak.waitForExistence(timeout: 5))
        let start = peak.frame.minX
        peak.swipeLeft()
        XCTAssertTrue(!peak.exists || peak.frame.minX < start - 50, "The row scrolls sideways")
        XCTAssertFalse(gallery.exists, "A sideways swipe keeps one row")

        handle.tap()
        XCTAssertTrue(gallery.waitForExistence(timeout: 5), "The handle opens it too")
        app.buttons["bot.studio.tab.eyes"].firstMatch.tap()
        XCTAssertFalse(gallery.exists, "Another tab shows its own row")
        XCTAssertFalse(handle.isHittable, "Only Body has the gallery")
    }

    /// A slow, deliberate drag from the middle of `element`, up for a negative `height`.
    @MainActor
    private func drag(_ element: XCUIElement, by height: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: height)))
    }

    /// PetDex shows only pets, opened on the agent's own.
    @MainActor
    func testPetDexShowsOnlyPets() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-agent-pet", "home:pip"]
        app.launch()
        openChooser(of: "home", in: app)
        app.descendants(matching: .any)["avatar.chooser.petdex"].firstMatch.tap()
        let pip = app.buttons["avatar.creator.pet.pip"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        let picked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: pip)
        XCTAssertEqual(XCTWaiter.wait(for: [picked], timeout: 10), .completed, "The agent's pet is picked")
        XCTAssertFalse(app.buttons["avatar.creator.category.bighelp"].exists, "Only pets")
        XCTAssertFalse(app.buttons["avatar.creator.category.other"].exists, "No Other section")
        save("petdex", app)
    }

    @MainActor
    private func openChooser(of agentID: String, in app: XCUIApplication) {
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
        XCTAssertTrue(app.descendants(matching: .any)["avatar.chooser.studio"].firstMatch.waitForExistence(timeout: 10))
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
