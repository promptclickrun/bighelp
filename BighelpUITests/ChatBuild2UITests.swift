import XCTest
import UIKit

final class ChatBuild2UITests: BighelpUITestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-v3-header-context", "-loopdy.demo.appearance", "light"]
        app.launch()
        return app
    }

    @MainActor
    func testCompactGlassHeaderAndUnifiedContextPill() {
        let app = launch()
        let create = app.buttons["chat.home.new-chat"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(create.frame.width, 44)
        XCTAssertGreaterThanOrEqual(create.frame.height, 44)
        let menu = app.buttons["chat.options"]
        if menu.exists {
            XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
            XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        }
        // The context window left the rail above the message box for the ⋯ menu.
        XCTAssertFalse(app.buttons["chat.session-context"].exists)
        XCTAssertTrue(chatMenuItem("chat.context-window", in: app).waitForExistence(timeout: 3))
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "unified-glass-header-and-context"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testHeaderControlsFlankCenteredBrand() throws {
        let app = launch()
        // Every phone chat uses the agent-home header: the live avatar in the middle,
        // ☰ (or Back) on the left, New chat on the right.
        let create = app.buttons["chat.home.new-chat"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let avatar = app.buttons["agent.hero.avatar"]
        XCTAssertEqual(avatar.frame.midX, app.frame.midX, accuracy: 1)
        let leading = app.buttons["chat.menu"].exists ? app.buttons["chat.menu"] : app.buttons["chat.back"]
        XCTAssertTrue(leading.exists)
        XCTAssertEqual(leading.frame.midY, create.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(avatar.frame.minX, leading.frame.maxX)
        XCTAssertLessThanOrEqual(avatar.frame.maxX, create.frame.minX)
    }

    @MainActor
    func testContextWindowOpensFromTheChatMenu() throws {
        let app = launch()
        let input = app.textViews["chat.composer.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists, "No context button above the message box")
        XCTAssertTrue(openContextWindow(in: app).exists)
        XCTAssertTrue(app.staticTexts["Context window"].waitForExistence(timeout: 3))
        for metric in [
            "Latest input", "Latest output", "Latest cached", "Latest request total",
            "Session input", "Session output", "Session cached", "Session total (incl. subagents)",
        ] {
            XCTAssertTrue(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", metric)).firstMatch.exists, metric)
        }
        evidence("context-details")
    }

    @MainActor
    func testGlassAppearancePreservesComposerAndDrawerActions() {
        defer {
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.appearance = .light
        }
        for mode in ["light", "dark"] {
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.appearance = mode == "dark" ? .dark : .light
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                                   "-preview-ui-v3", "-test-v3-header-context", "-loopdy.demo.appearance", mode]
            app.launch()
            app.textViews["chat.composer.text"].tap()
            app.buttons["chat.options"].tap()
            let picker = app.buttons["chat.session-controls"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            let initial = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            initial.name = "glass-chat-\(mode)-idle"
            initial.lifetime = .keepAlways
            add(initial)
            picker.tap()
            let seeAllModels = app.buttons["chat.models.see-all"]
            XCTAssertTrue(seeAllModels.waitForExistence(timeout: 3))
            seeAllModels.tap()
            XCTAssertTrue(app.otherElements["model-picker.surface"].waitForExistence(timeout: 3))
            app.terminate()
            app.launch()
            let input = app.textViews["Message"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            let original = input.value as? String ?? ""
            if !original.isEmpty { input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count)) }
            input.typeText("Glass composer keeps this draft.")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertTrue(send.isEnabled)
            XCTAssertEqual(input.value as? String, "Glass composer keeps this draft.")
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.exists)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY)
            let typed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            typed.name = "glass-chat-\(mode)-keyboard"
            typed.lifetime = .keepAlways
            add(typed)
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.tables["chat.timeline"].frame
                return frame.width > frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertEqual(input.value as? String, "Glass composer keeps this draft.")
            XCTAssertTrue(send.isHittable)
            XCTAssertLessThanOrEqual(send.frame.maxY, keyboard.frame.minY)
            let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            landscape.name = "glass-chat-\(mode)-landscape-keyboard"
            landscape.lifetime = .keepAlways
            add(landscape)
            XCUIDevice.shared.orientation = .portrait
            app.buttons["chat.attachment"].tap()
            XCTAssertTrue(app.otherElements["chat.action-drawer.surface"].waitForExistence(timeout: 4))
            app.terminate()
        }
    }

    @MainActor
    func testPetDoesNotCoverUnifiedStatusControls() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-v3-header-context", "-use-overflow-status-rail-fixture", "-test-v3-session-status",
                               "-test-companion-character", "clip"]
        app.launch()
        let pet = app.descendants(matching: .any)["companion-chat"].firstMatch
        XCTAssertTrue(pet.waitForExistence(timeout: 6))
        for kind in ["changes", "goal", "subagents", "tasks"] {
            let control = app.buttons["chat.session-status.\(kind)"]
            XCTAssertTrue(control.exists)
            XCTAssertFalse(pet.frame.insetBy(dx: 2, dy: 2).intersects(control.frame),
                           "Resting companion must not cover \(kind).")
            XCTAssertTrue(control.isHittable)
        }
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "glass-rail-companion-clearance"
        capture.lifetime = .keepAlways
        add(capture)
    }

    @MainActor
    func testNoStatusPillWhenNoStatusOrContextIsNeeded() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.chat.showProjectChanges", "NO", "-test-companion-disabled"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.home.new-chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists)
        XCTAssertFalse(app.otherElements["chat.session-status-rail"].exists)
    }

    @MainActor
    func testAssistantLongPressOffersMessageActions() throws {
        let app = launch()
        let text = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND NOT label BEGINSWITH %@",
            "chat.message.inline-selection",
            "You:"
        )).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 10))
            .press(forDuration: 1.0)
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy to clipboard")).firstMatch
        let select = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select text")).firstMatch
        let fork = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Fork from here")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertTrue(fork.waitForExistence(timeout: 3))
        select.tap()
        XCTAssertTrue(app.navigationBars["Select text"].waitForExistence(timeout: 3))
        evidence("assistant-message-actions")
    }

    @MainActor
    func testHumanLongPressKeepsMessageMenu() throws {
        let app = launch()
        let human = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@",
            "chat.message.inline-selection",
            "You: A calmer chat"
        )).firstMatch
        XCTAssertTrue(human.waitForExistence(timeout: 5))
        human.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 10))
            .press(forDuration: 1)
        for label in ["Copy to clipboard", "Select text", "Fork from here"] {
            let action = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@",
                label
            )).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 3), "Missing \(label) for a human message")
        }
        evidence("human-menu")
    }

    @MainActor
    func testDoubleTapUsesNativeInlineSelectionForBothMessageRoles() throws {
        let app = launch()
        let messages = app.textViews.matching(identifier: "chat.message.inline-selection")
        XCTAssertGreaterThanOrEqual(messages.count, 2)
        let allMessages = messages.allElementsBoundByIndex
        let human = try XCTUnwrap(allMessages.first { $0.label.hasPrefix("You:") })
        let assistant = try XCTUnwrap(allMessages.first { !$0.label.hasPrefix("You:") })

        for message in [human, assistant] {
            message.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 20, dy: 10))
                .doubleTap()
            let nativeCopy = app.descendants(matching: .any).matching(NSPredicate(
                format: "label == %@",
                "Copy"
            )).firstMatch
            XCTAssertTrue(
                nativeCopy.waitForExistence(timeout: 3),
                "Double tap must expose UIKit's range-scoped Copy action for \(message.label)"
            )
            XCTAssertFalse(app.navigationBars["Select text"].exists)
            nativeCopy.tap()
        }
        evidence("both-roles-native-double-tap-selection")
    }

    @MainActor
    func testFavoritesCanBePinnedFromModelCatalog() throws {
        let app = launch()
        app.textViews["chat.composer.text"].tap()
        app.buttons["chat.options"].tap()
        let picker = app.buttons["chat.session-controls"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let seeAllModels = app.buttons["chat.models.see-all"]
        XCTAssertTrue(seeAllModels.waitForExistence(timeout: 3))
        seeAllModels.tap()
        let search = app.searchFields["Search providers and models"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("gpt-5.6")
        let pin = app.buttons["model-picker.pin.openai.gpt-5.6"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        guard pin.exists else { return }
        if pin.label.contains("Unpin") { pin.tap() }
        pin.tap()
        XCTAssertTrue(pin.label.contains("Unpin"))
        evidence("pinned-model")
        app.terminate()
        app.launch()
        app.textViews["chat.composer.text"].tap()
        app.buttons["chat.options"].tap()
        app.buttons["chat.session-controls"].tap()
        let cleanupSeeAll = app.buttons["chat.models.see-all"]
        XCTAssertTrue(cleanupSeeAll.waitForExistence(timeout: 3))
        cleanupSeeAll.tap()
        let cleanupSearch = app.searchFields["Search providers and models"]
        XCTAssertTrue(cleanupSearch.waitForExistence(timeout: 5))
        cleanupSearch.tap()
        cleanupSearch.typeText("gpt-5.6")
        XCTAssertTrue(app.buttons["model-picker.pin.openai.gpt-5.6"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["model-picker.pin.openai.gpt-5.6"].label.contains("Unpin"))
        evidence("pinned-model-after-relaunch")
        let cleanupPin = app.buttons["model-picker.pin.openai.gpt-5.6"]
        XCTAssertTrue(cleanupPin.waitForExistence(timeout: 3))
        cleanupPin.tap()
        XCTAssertTrue(cleanupPin.label.contains("Pin"))
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "build2-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("build2-\(name).png"))
        }
    }
}
