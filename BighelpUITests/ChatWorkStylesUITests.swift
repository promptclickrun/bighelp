import XCTest

/// Settings › Chat › Agent's work in a Bots chat, on the demo tool stream (two notes, each before a tool,
/// then the answer). Card and Minimal gather the running turn into one block; Full keeps every step in
/// place. When the turn ends the work folds: above the answer, or under it for Minimal.
final class ChatWorkStylesUITests: BighelpUITestCase {
    @MainActor
    func testEachStyleShowsTheRunningTurnAndFoldsItWhenItEnds() throws {
        for appearance in ["light", "dark"] {
            for style in ["card", "minimal", "full"] {
                let app = makeApp()
                app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                       "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance,
                                       "-bighelp.chat.work-style", style,
                                       "-test-tool-stream", "-test-tool-stream-two-turns", "-test-tool-stream-slow",
                                       "-test-tool-stream-settles"]
                app.launch()
                XCTAssertTrue(app.buttons["simple-bots.primary"].waitForExistence(timeout: 15))
                app.buttons["simple-bots.primary"].tap()
                let input = app.textViews["chat.composer.text"]
                XCTAssertTrue(input.waitForExistence(timeout: 10))
                input.tap()
                input.typeText("Check the source")
                app.buttons["chat.send"].tap()

                let block = app.buttons["chat.live-work"]
                let note = app.descendants(matching: .any).matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@", "Investigation step 1", "Investigation step 1"))
                    .firstMatch
                if style == "full" {
                    XCTAssertTrue(note.waitForExistence(timeout: 10), "Full shows each note in place")
                    XCTAssertFalse(block.exists, "Full has no block")
                } else {
                    XCTAssertTrue(block.waitForExistence(timeout: 10), "\(style) gathers the work into one block")
                    XCTAssertEqual(block.value as? String, "Collapsed")
                    if style == "card" { XCTAssertTrue(block.label.contains("is working"), block.label) }
                }
                save("live-\(style)-\(appearance)", app)

                let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "TOOL STREAM COMPLETE"))
                    .firstMatch
                XCTAssertTrue(answer.waitForExistence(timeout: 30), "The answer")
                XCTAssertTrue(block.waitForNonExistence(timeout: 5), "The block leaves when the turn ends")
                // This turn's fold, named for its first note (the demo chat has an earlier turn too).
                let fold = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
                                                            "chat.completed-turn:message:", "prose")).firstMatch
                XCTAssertTrue(fold.waitForExistence(timeout: 5), "The work folds")
                XCTAssertEqual(fold.value as? String, "Collapsed")
                XCTAssertTrue(note.waitForNonExistence(timeout: 5), "Its notes fold with it")
                for _ in 0..<6 where !fold.isHittable {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: style == "minimal" ? 0.7 : 0.35))
                        .press(forDuration: 0.05, thenDragTo: app.coordinate(
                            withNormalizedOffset: CGVector(dx: 0.5, dy: style == "minimal" ? 0.35 : 0.8)))
                }
                if style == "minimal" {
                    XCTAssertGreaterThan(fold.frame.minY, answer.frame.minY, "Minimal's receipt sits under the answer")
                } else {
                    XCTAssertLessThan(fold.frame.minY, answer.frame.minY, "The fold sits where the work began")
                }
                save("done-\(style)-\(appearance)", app)

                fold.tap()
                XCTAssertEqual(fold.value as? String, "Expanded")
                XCTAssertTrue(note.waitForExistence(timeout: 5), "A tap opens the steps and notes")
                save("opened-\(style)-\(appearance)", app)
                app.terminate()
            }
        }
    }

    /// The picker is in Settings › Chat for everyone, without Nerd Mode.
    @MainActor
    func testAgentWorkPickerIsAnEverydayChatSetting() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.settings.nerd-mode", "NO", "-bighelp.chat.work-style", "card",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            openRootTab("tab.profile", in: app)
            settingsRow("settings.menu.chat", in: app).tap()
            let picker = app.buttons["settings.chat.work-style"].firstMatch
            for _ in 0..<4 where !(picker.exists && picker.isHittable) { app.swipeUp() }
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.label.contains("Card"), picker.label)
            save("work-style-picker-\(appearance)", app)
            picker.tap()
            let minimal = app.buttons["Minimal"].firstMatch
            XCTAssertTrue(minimal.waitForExistence(timeout: 5))
            minimal.tap()
            XCTAssertTrue(picker.label.contains("Minimal"), picker.label)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
