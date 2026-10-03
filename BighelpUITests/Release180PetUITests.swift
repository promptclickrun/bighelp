import XCTest

final class Release180PetUITests: BighelpUITestCase {
    @MainActor
    func testPetSizeAlsoAppliesToVoiceWithoutMovingControls() {
        var smallWidth: CGFloat?
        for scale in ["0.6", "1.5"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-companion-character", "clip", "-test-companion-scale", scale, "-test-companion-reduced-motion", "-start-chat"]
            app.launch()
            addUIInterruptionMonitor(withDescription: "Voice permission") { alert in
                for title in ["Don’t Allow", "Don't Allow"] where alert.buttons[title].exists { alert.buttons[title].tap(); return true }
                return false
            }
            XCTAssertTrue(app.buttons["chat.voice"].waitForExistence(timeout: 5))
            app.buttons["chat.voice"].tap()
            let end = app.buttons["voice.end"]
            XCTAssertTrue(end.waitForExistence(timeout: 6))
            let pet = app.descendants(matching: .any)["companion-voice"].firstMatch
            XCTAssertTrue(pet.waitForExistence(timeout: 4))
            XCTAssertFalse(pet.frame.intersects(end.frame))
            if let smallWidth { XCTAssertGreaterThan(pet.frame.width, smallWidth + 20) }
            else { smallWidth = pet.frame.width }
            end.tap()
            app.terminate()
        }
    }

    @MainActor
    func testDefaultHomeLoaderUsesAnimatedInfinityInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-companion-disabled", "-test-home-loading", "-loopdy.demo.appearance", appearance]
            app.launch()
            let mark = app.descendants(matching: .any)["loopdy.thinking-mark"].firstMatch
            XCTAssertTrue(mark.waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["companion-home"].firstMatch.exists)
            XCTAssertFalse(app.descendants(matching: .any)["companion-home-loading"].firstMatch.exists)
            let first = mark.screenshot().pngRepresentation
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "thinking-mark-\(appearance)"; shot.lifetime = .keepAlways; add(shot)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            XCTAssertNotEqual(mark.screenshot().pngRepresentation, first)
            app.terminate()
        }
    }

    @MainActor
    func testAdventurousPetActuallyTravelsAndLeavesControlsUsable() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-companion-character", "clip", "-test-companion-adventure", "on", "-test-companion-scale", "1", "-start-chat", "-preview-ui-v3", "-test-v3-header-context"]
        app.launch()
        let pet = app.descendants(matching: .any)["companion-chat"].firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 6))
        var positions: [CGPoint] = []
        for _ in 0..<12 {
            positions.append(CGPoint(x: pet.frame.midX, y: pet.frame.midY))
            XCTAssertTrue(app.frame.contains(pet.frame))
            XCTAssertTrue(app.buttons["chat.attachment"].isHittable)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertGreaterThan((positions.map(\.x).max() ?? 0) - (positions.map(\.x).min() ?? 0), 80)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "adventurous-pet-in-chat"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["chat.attachment"].tap()
        XCTAssertTrue(app.buttons["chat.action.workspace"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSizeAndAdventurousSettingsSurviveAppRelaunch() {
        let app = launch()
        func openSettings() {
            self.openSettings(in: app)
            let entry = settingsRow("companion-settings-entry", in: app)
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            entry.tap()
        }
        openSettings()
        let size = app.sliders["companion.size"]
        XCTAssertTrue(size.waitForExistence(timeout: 4))
        size.adjust(toNormalizedSliderPosition: 0.8)
        let chosenSize = size.value as? String
        let adventure = app.switches["companion.adventurous"]
        if adventure.value as? String != "1" { adventure.switches.firstMatch.exists ? adventure.switches.firstMatch.tap() : adventure.tap() }
        XCTAssertEqual(adventure.value as? String, "1")
        app.terminate()
        app.launch()
        openSettings()
        XCTAssertEqual(app.sliders["companion.size"].value as? String, chosenSize)
        XCTAssertEqual(app.switches["companion.adventurous"].value as? String, "1")
        app.buttons["companion.size.reset"].tap()
        app.switches["companion.adventurous"].tap()
    }

    @MainActor
    private func launch(chat: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-companion-character", "clip", "-test-companion-reduced-motion"]
        if chat { app.launchArguments += ["-start-chat", "-preview-ui-v3", "-test-v3-header-context"] }
        app.launch()
        return app
    }

    @MainActor
    func testCompanionSizeAndAdventureControlsExist() {
        let app = launch()
        openSettings(in: app)
        var entry = settingsRow("companion-settings-entry", in: app)
        if !entry.waitForExistence(timeout: 2) {
            settingsRow("settings.menu.appearance", in: app).tap()
            entry = settingsRow("companion-settings-entry", in: app)
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 4))
        entry.tap()
        XCTAssertTrue(app.sliders["companion.size"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.switches["companion.adventurous"].exists)
        XCTAssertTrue(app.buttons["companion.size.reset"].exists)
    }

    @MainActor
    func testRestingPetSitsOnTheMessageBox() {
        let app = launch(chat: true)
        let pet = app.descendants(matching: .any)["companion-chat"].firstMatch
        let field = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 6))
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        // With no context ring above the message box, the pet rests on the message row's top.
        XCTAssertLessThan(abs(pet.frame.maxY - field.frame.minY), 30)
        XCTAssertLessThanOrEqual(pet.frame.maxX, field.frame.maxX + 2)
        XCTAssertTrue(app.buttons["chat.attachment"].isHittable)
    }

    @MainActor
    func testHomeLoadingUsesOnePetInsteadOfOrb() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-test-companion-character", "clip", "-test-home-loading"]
        app.launch()
        let pet = app.descendants(matching: .any)["companion-home-loading"].firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["companion-home"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["loopdy.thinking-mark"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-one-loading-pet"; shot.lifetime = .keepAlways; add(shot)
    }
}
