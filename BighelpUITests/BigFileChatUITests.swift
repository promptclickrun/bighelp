import XCTest

/// A big file in a sent message (#721), on the demo data: the tile while it goes up (34 of 80 MB),
/// not sent with Try again, and once Hermes has it, a line on the rail. The path never shows as
/// text, and a tap on the line opens the bot's Files. BIGHELP_ATTACHMENT_EVIDENCE saves screenshots.
final class BigFileChatUITests: BighelpUITestCase {
    @MainActor
    func testATileWhileItGoesUpThenALineThatOpensFiles() throws {
        for appearance in ["light", "dark"] {
            var app = launch("big-file-uploading", appearance: appearance)
            let tile = app.descendants(matching: .any)["chat.big-file"]
            XCTAssertTrue(tile.waitForExistence(timeout: 15), "The tile shows while the file goes up")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '34 of'")).firstMatch.exists)
            XCTAssertFalse(app.descendants(matching: .any)["chat.sent-file"].exists, "No line while it goes up")
            save("big-file-uploading-\(appearance)", app)
            app.terminate()

            app = launch("big-file-failed", appearance: appearance)
            let retry = app.buttons["chat.big-file.retry"]
            XCTAssertTrue(retry.waitForExistence(timeout: 15), "A file that didn't go offers Try again")
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'out of space'")).firstMatch.exists)
            save("big-file-failed-\(appearance)", app)
            retry.tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '34 of'")).firstMatch
                .waitForExistence(timeout: 5), "Try again goes on from the pieces the computer has")
            app.terminate()

            app = launch("big-file-sent", appearance: appearance)
            let line = app.descendants(matching: .any)["chat.sent-file"]
            XCTAssertTrue(line.waitForExistence(timeout: 15), "Once Hermes has it, the file is a line on the rail")
            XCTAssertTrue(line.label.contains("Trip to the coast.mov"), line.label)
            XCTAssertFalse(tile.exists)
            // Message text is a text view, so look at every element's label and value, not static texts.
            let raw = NSPredicate(format: "label CONTAINS '/home/fixture' OR value CONTAINS '/home/fixture' "
                + "OR label CONTAINS '@file:' OR value CONTAINS '@file:' OR value CONTAINS 'attached:'")
            XCTAssertEqual(app.descendants(matching: .any).matching(raw).count, 0, "No path or reference as text")
            let words = app.textViews.matching(identifier: "chat.message.inline-selection")
                .containing(NSPredicate(format: "value CONTAINS 'from Saturday'")).firstMatch
            XCTAssertTrue(words.exists || app.descendants(matching: .any)
                .matching(NSPredicate(format: "value CONTAINS 'from Saturday'")).firstMatch.exists)
            save("big-file-sent-\(appearance)", app)
            line.tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile.files"].waitForExistence(timeout: 10),
                          "A tap opens the bot's Files")
            save("big-file-opened-files-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor private func launch(_ hold: String, appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-loopdy.demo.appearance", appearance, "-test-draft-attachments", hold]
        app.launch()
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_ATTACHMENT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
