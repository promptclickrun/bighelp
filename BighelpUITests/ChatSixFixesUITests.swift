import XCTest
import UIKit

final class ChatSixFixesUITests: BighelpUITestCase {
    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-v3-header-context", "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"] + extra
        app.launch()
        return app
    }

    @MainActor
    func testAssistantActionsUseNativeSelectionWithoutAVisibleToolbar() throws {
        let app = launch()
        let assistant = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND NOT label BEGINSWITH %@",
            "chat.message.inline-selection",
            "You:"
        )).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.message.copy"].exists)
        XCTAssertFalse(app.buttons["chat.message.select-text"].exists)
        XCTAssertFalse(app.buttons["chat.message.fork"].exists)
        assistant.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy to clipboard"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Select text"].exists)
        XCTAssertTrue(app.buttons["Fork from here"].exists)
        evidence("message-actions")
    }

    @MainActor
    func testLongPressReactSupportsUserAndAssistantMessagesWithoutStandaloneAffordance() throws {
        let app = launch(["-test-native-reaction-ui"])
        XCTAssertFalse(app.buttons["Message reactions"].exists)

        try chooseReaction(
            "👍",
            forMessageContaining: "Room for the conversation.",
            in: app
        )

        try chooseReaction(
            "🚀",
            forMessageContaining: "A calmer chat, with all of our tools.",
            in: app,
            usingAnyEmojiField: true
        )
        XCTAssertFalse(app.buttons["Message reactions"].exists)
        evidence("long-press-message-reactions")
    }

    @MainActor
    private func chooseReaction(
        _ emoji: String,
        forMessageContaining text: String,
        in app: XCUIApplication,
        usingAnyEmojiField: Bool = false
    ) throws {
        let message = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "chat.message.",
            text
        )).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let surface = message.descendants(matching: .textView)
            .matching(identifier: "chat.message.inline-selection").firstMatch
        let target = surface.exists ? surface : message
        target.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 12, dy: 10)).press(forDuration: 1)
        let react = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "React")).firstMatch
        XCTAssertTrue(react.waitForExistence(timeout: 3))
        react.tap()
        let picker = app.descendants(matching: .any)["chat.reaction-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        if usingAnyEmojiField {
            let field = app.textFields["chat.reaction-picker.any-emoji"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.tap()
            field.typeText(emoji)
            app.buttons["Add reaction"].tap()
        } else {
            let choice = app.buttons["React \(emoji)"]
            XCTAssertTrue(choice.waitForExistence(timeout: 3))
            choice.tap()
        }
        XCTAssertTrue(picker.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testAssistantPaddingRetainsFullMessageActions() throws {
        let app = launch()
        let assistant = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND NOT label BEGINSWITH %@",
            "chat.message.inline-selection",
            "You:"
        )).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertTrue(assistant.isHittable)
        // Use trailing padding: the screen's leading 28 points belong to its
        // edge-navigation overlay, not the message. This stays outside text.
        assistant.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: 8, dy: 12)).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Copy to clipboard"].waitForExistence(timeout: 3)
                      || app.menuItems["Copy to clipboard"].exists)
        XCTAssertTrue(app.buttons["Select text"].exists || app.menuItems["Select text"].exists)
        XCTAssertTrue(app.buttons["Fork from here"].exists || app.menuItems["Fork from here"].exists)
        evidence("assistant-padding-full-message-actions")
    }

    @MainActor
    func testLongUnbrokenDraftStaysInsideComposerBounds() throws {
        let app = launch()
        let editor = app.textViews["chat.composer.text"].firstMatch
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.exists)

        editor.tap()
        editor.typeText(String(repeating: "unbroken", count: 30))

        XCTAssertGreaterThanOrEqual(editor.frame.minX, composer.frame.minX)
        XCTAssertLessThanOrEqual(editor.frame.maxX, composer.frame.maxX,
                                 "Draft text view must remain inside the composer bubble")
        XCTAssertLessThanOrEqual(editor.frame.maxX, app.frame.maxX)
        evidence("long-unbroken-draft-contained")
    }

    @MainActor
    func testMultilineDraftUsesTheComposerWidthAndRemainsContained() throws {
        let app = launch()
        let editor = app.textViews["chat.composer.text"].firstMatch
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.exists)

        editor.tap()
        editor.typeText("In The Input Field")

        XCTAssertGreaterThan(editor.frame.width, composer.frame.width * 0.55,
                             "The editor must consume the available capsule width instead of wrapping every word")
        XCTAssertGreaterThanOrEqual(editor.frame.minX, composer.frame.minX)
        XCTAssertLessThanOrEqual(editor.frame.maxX, composer.frame.maxX)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, composer.frame.minY)
        XCTAssertLessThanOrEqual(editor.frame.maxY, composer.frame.maxY)
        evidence("multiline-draft-contained")
    }

    @MainActor
    func testStatusRailIsOneCompactRowWithoutTheContextWindow() throws {
        let app = launch(["-use-overflow-status-rail-fixture", "-test-v3-session-status"])
        let rail = app.descendants(matching: .any)["chat.session-status-rail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists, "The context window lives in the ⋯ menu")
        XCTAssertLessThanOrEqual(app.buttons["chat.session-status.goal"].frame.height, 44.5)
        XCTAssertLessThanOrEqual(rail.frame.maxY,
                                 app.descendants(matching: .any)["chat.composer-shell"].firstMatch.frame.minY)
        XCTAssertGreaterThanOrEqual(rail.frame.minX, app.frame.minX)
        evidence("compact-rail")
    }

    @MainActor
    func testPhoneShowsAllThreeActivitiesWithoutHorizontalHunting() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Compact phone layout") }
        let app = launch(["-use-overflow-status-rail-fixture", "-test-v3-session-status"])
        XCTAssertTrue(chatNewChatButton(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists)
        let buttons = ["goal", "subagents", "tasks"].map {
            app.buttons["chat.session-status.\($0)"]
        }
        for button in buttons {
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 12)
            XCTAssertLessThanOrEqual(button.frame.maxX + 4, app.frame.maxX - 8,
                                    "Every activity must be wholly visible without horizontal scrolling")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            XCTAssertEqual(button.frame.midY, buttons[0].frame.midY, accuracy: 0.5)
        }
        for pair in zip(buttons, buttons.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.frame.maxX, pair.1.frame.minX)
        }
        let timeline = app.tables["chat.timeline"]
        let finalAction = app.buttons.matching(identifier: "chat.message.fork").allElementsBoundByIndex.last
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        print("CHAT_CLEARANCE timeline=\(timeline.frame) finalAction=\(String(describing: finalAction?.frame)) composer=\(composer.frame)")
        evidence("phone-all-activities")
    }

    @MainActor
    func testPhoneActivityStripRemainsReadableAtAccessibilityXXXL() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Compact phone layout") }
        let app = launch(["-use-overflow-status-rail-fixture", "-test-v3-session-status",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(chatNewChatButton(in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-context"].exists)
        let buttons = ["goal", "subagents", "tasks"].map {
            app.buttons["chat.session-status.\($0)"]
        }
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        let rail = app.descendants(matching: .any)["chat.session-status-rail"].firstMatch
        for (button, title) in zip(buttons, ["Goal", "Agents", "Tasks"]) {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThanOrEqual(button.frame.minX, app.frame.minX + 12)
            XCTAssertTrue(rail.frame.insetBy(dx: -1, dy: -1).contains(button.frame),
                          "Status bounds \(button.frame) must fit the glass rail \(rail.frame).")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            // A goal's detail may wrap at accessible sizes. Measure its short
            // title, not the combined title/detail row, for this invariant.
            let titleLabel = button.staticTexts[title]
            XCTAssertTrue(titleLabel.exists)
            XCTAssertLessThanOrEqual(titleLabel.frame.height, 64,
                                    "Short activity titles must not break across lines at large text sizes")
            for label in button.staticTexts.allElementsBoundByIndex {
                XCTAssertTrue(button.frame.insetBy(dx: -1, dy: -1).contains(label.frame),
                              "The complete title and detail must fit inside their activity row.")
            }
            XCTAssertLessThanOrEqual(button.frame.maxY, composer.frame.minY)
        }
        for (index, button) in buttons.enumerated() {
            for other in buttons.dropFirst(index + 1) {
                XCTAssertFalse(button.frame.insetBy(dx: 1, dy: 1).intersects(other.frame))
            }
        }
        XCTAssertLessThan(buttons[0].frame.midY, buttons[2].frame.midY)
        evidence("phone-accessibility-activities")
        buttons[2].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testFileChangesMenuItemShowsDiffCountsAndOpensProjectDetails() throws {
        let app = launch(["-use-overflow-status-rail-fixture", "-test-v3-session-status"])
        let changes = chatMenuItem("chat.file-changes", in: app)
        XCTAssertTrue(changes.waitForExistence(timeout: 5))
        XCTAssertTrue(changes.label.contains("1 file"))
        XCTAssertTrue(changes.label.contains("12 additions"))
        XCTAssertTrue(changes.label.contains("4 deletions"))
        changes.tap()
        XCTAssertTrue(app.staticTexts["Project Changes"].waitForExistence(timeout: 3))
        evidence("compact-project-details")
    }

    @MainActor
    func testAllCompactRailDestinationsRemainReachable() throws {
        let app = launch(["-use-overflow-status-rail-fixture", "-test-v3-session-status"])
        let rail = app.descendants(matching: .any)["chat.session-status-rail"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.session-status.changes"].exists, "File changes live in the ⋯ menu")
        XCTAssertFalse(app.buttons["chat.session-context"].exists, "The context window lives in the ⋯ menu")
        for kind in ["goal", "subagents", "tasks"] {
            let button = app.buttons["chat.session-status.\(kind)"]
            XCTAssertTrue(button.exists)
            for _ in 0..<6 where !button.isHittable || button.frame.maxX > app.frame.maxX - 12 {
                rail.swipeLeft()
            }
            XCTAssertTrue(button.isHittable)
            XCTAssertLessThanOrEqual(button.frame.maxX, app.frame.maxX - 12)
            XCTAssertLessThanOrEqual(button.frame.height, 44.5)
            evidence("rail-\(kind)")
            button.tap()
            let done = app.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 3), "\(kind) must open its actual drawer")
            evidence("drawer-\(kind)")
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 3))
        }
        XCTAssertTrue(openContextWindow(in: app).exists, "The context window opens from ⋯")
    }

    @MainActor
    func testSlashCommandDoesNotPaintPlaceholderOverChipOrArguments() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"])
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("/")
        let help = app.buttons["reference-hub.command.help"]
        XCTAssertTrue(help.waitForExistence(timeout: 4))
        help.tap()
        XCTAssertTrue(app.otherElements["reference-hub.drawer"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["reference-hub.command.insert"].exists)
        XCTAssertEqual(input.value as? String, "/help ")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        // The command is now native inline source. Match the text view's body
        // font and zero text-container padding to sample its empty arguments,
        // excluding the command glyphs/caret without depending on a removed chip.
        let bodyFont = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let commandWidth = ("/help " as NSString).size(withAttributes: [.font: bodyFont]).width
        let commandEnd = input.frame.minX + commandWidth
        let crop = CGRect(x: commandEnd + 8, y: input.frame.midY - 12,
                          width: max(0, input.frame.maxX - commandEnd - 16), height: 24)
        XCTAssertGreaterThan(crop.width, 10)
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let region = try XCTUnwrap(image.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                                            width: crop.width * scale, height: crop.height * scale)))
        var pixels = [UInt8](repeating: 0, count: region.width * region.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: region.width, height: region.height,
                bitsPerComponent: 8, bytesPerRow: region.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(region, in: CGRect(x: 0, y: 0, width: region.width, height: region.height))
        }
        var textInk = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i+1]), Int(pixels[i+2])]
            if rgb.max()! < 160 { textInk += 1 }
        }
        evidence("slash-empty-arguments")
        XCTAssertLessThan(textInk, 10, "Empty argument area must not contain the Message placeholder")
        input.typeText("details")
        XCTAssertTrue((input.value as? String ?? "").contains("details"))
        XCTAssertEqual(input.value as? String, "/help details")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
    }

    @MainActor
    func testExpandedLongPromptCanReachAndEditFinalLine() throws {
        try verifyLongPrompt(sourceMode: false)
    }

    @MainActor
    func testExpandedNumberedListCanReachAndEditFinalLine() throws {
        try verifyLongPrompt(sourceMode: true)
    }

    @MainActor
    private func verifyLongPrompt(sourceMode: Bool) throws {
        let app = launch()
        let compact = app.textViews["Message"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        compact.typeText(sourceMode ? "1. Long prompt\n" : "Long prompt\n")
        app.otherElements["chat.composer-shell"].pinch(withScale: 1.8, velocity: 1)
        let mode = app.buttons["reference-hub.editor-mode"]
        XCTAssertEqual(mode.label, "Rich text", "Expanded references must start in source mode")
        if !sourceMode {
            mode.tap()
            XCTAssertEqual(mode.label, "References / Markdown")
            XCTAssertEqual(app.buttons["chat.composer.expanded.mode"].label, "Markdown",
                           "The rich branch must exercise the actual rich editor")
        }
        let editor = app.textViews["Expanded message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        if sourceMode {
            XCTAssertEqual(mode.label, "Rich text")
            XCTAssertEqual(editor.value as? String, "1. Long prompt\n")
        }
        editor.tap()
        let paragraph = String(repeating: "Keep this paragraph editable and scrollable. ", count: 8)
        for index in 1...8 {
            editor.typeText("\(sourceMode ? "\(index + 1)." : "Item \(index):") \(paragraph)\n\n")
        }
        editor.typeText("END-OF-LONG-PROMPT")
        XCTAssertTrue((editor.value as? String ?? "").contains("END-OF-LONG-PROMPT"))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1,
                                 "The editor viewport must stop above the keyboard")
        let tail = editor.screenshot().pngRepresentation
        evidence("expanded-long-tail")
        editor.swipeDown(velocity: .fast)
        editor.swipeDown(velocity: .fast)
        XCTAssertNotEqual(editor.screenshot().pngRepresentation, tail, "Scrolling must reveal earlier text")
        editor.swipeUp(velocity: .fast)
        editor.swipeUp(velocity: .fast)
        editor.typeText("-EDITED")
        XCTAssertTrue((editor.value as? String ?? "").contains("END-OF-LONG-PROMPT-EDITED"))
        evidence("expanded-long-edited")
        app.buttons["chat.composer.expanded.collapse"].tap()
        XCTAssertTrue((compact.value as? String ?? "").contains("END-OF-LONG-PROMPT-EDITED"))
    }

    @MainActor
    func testTypingNumberedItemIntoRichLongDraftDoesNotBlockEditing() throws {
        let app = launch()
        let compact = app.textViews["Message"]
        XCTAssertTrue(compact.waitForExistence(timeout: 5))
        compact.tap()
        compact.typeText("1: First item\n")
        app.buttons["chat.composer.expand"].tap()
        let mode = app.buttons["reference-hub.editor-mode"]
        XCTAssertEqual(mode.label, "Rich text")
        mode.tap()
        XCTAssertEqual(mode.label, "References / Markdown")
        XCTAssertEqual(app.buttons["chat.composer.expanded.mode"].label, "Markdown",
                       "Numbered typing must exercise the actual rich editor")
        let editor = app.textViews["Expanded message"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let paragraph = String(repeating: "A detailed request with room to scroll. ", count: 6)
        for index in 2...4 { editor.typeText("\(index): \(paragraph)\n\n") }
        editor.typeText("5. ")
        evidence("mixed-numbering-fifth-item")
        XCTAssertFalse(app.alerts["Change not applied"].exists,
                       "Typing a list marker must never interrupt or discard a draft")
        guard !app.alerts.firstMatch.exists else { return }
        editor.typeText("Continue the fifth item\n6. Finish the message")
        XCTAssertTrue((editor.value as? String ?? "").contains("6. Finish the message"))
        evidence("mixed-numbering-completed")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        evidence("mixed-numbering-landscape")
        XCTAssertLessThanOrEqual(editor.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertGreaterThan(editor.frame.height, 30)
        editor.typeText(" completed")
        let finalText = editor.value as? String ?? ""
        XCTAssertTrue(finalText.contains("6. Finish the message completed"))
        XCTAssertTrue(finalText.contains("1: First item"), "Switching editors must retain the original draft")
    }

    @MainActor
    private func evidence(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-six-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("chat-six-\(name).png"))
        }
    }
}
