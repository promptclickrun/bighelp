import XCTest

/// A Feed post with files, in demo mode: the post shows them compactly, a tap opens the
/// post, and a file opens a preview with Save and Share. BIGHELP_BOARD_EVIDENCE (a folder)
/// also saves light and dark screenshots for review.
final class FeedPostFilesUITests: BighelpUITestCase {
    @MainActor
    func testAPostsFilesOpenToPreviewSaveAndShare() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            openRootTab("tab.feed", in: app)
            let strip = app.buttons["board.feed.files.feed-1"]
            XCTAssertTrue(strip.waitForExistence(timeout: 10), "The post shows its files")
            XCTAssertEqual(strip.label, "2 attachments: 1 picture, Lisbon trip options.pdf")
            let raw = NSPredicate(format: "label CONTAINS 'MEDIA:' OR label BEGINSWITH '/'")
            XCTAssertEqual(app.descendants(matching: .any).matching(raw).count, 0, "No raw path or MEDIA line shows")
            let thumbnail = app.descendants(matching: .any)["Picture: october-fares.png"]
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 10), "The picture's thumbnail loads")
            save("feed-files-1-post-\(appearance)", app)

            strip.tap()
            let detail = app.descendants(matching: .any)["board.feed.detail"]
            XCTAssertTrue(detail.waitForExistence(timeout: 5), "A tap opens the post")
            let picture = app.buttons["board.feed.detail.file.0"]
            let pdf = app.buttons["board.feed.detail.file.1"]
            XCTAssertTrue(picture.waitForExistence(timeout: 5) && pdf.exists, "…with every file")
            XCTAssertEqual(pdf.label, "Lisbon trip options.pdf")
            save("feed-files-2-detail-\(appearance)", app)

            if appearance == "light" {
                // Hold a file to share or save it without opening it.
                pdf.press(forDuration: 1.2)
                XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5), "Holding a file offers Share")
                XCTAssertTrue(app.buttons["Save to Files"].exists)
                save("feed-files-3-menu", app)
                app.buttons["Open"].tap()
                XCTAssertTrue(app.buttons["chat.attachment.share"].waitForExistence(timeout: 10),
                              "The PDF opens in the preview with Share")
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(picture.waitForExistence(timeout: 5))
            }

            picture.tap()
            let share = app.buttons["chat.attachment.share"]
            XCTAssertTrue(share.waitForExistence(timeout: 10), "The picture opens in the preview")
            XCTAssertTrue(app.buttons["chat.attachment.save"].isEnabled, "…with Save")
            save("feed-files-4-preview-\(appearance)", app)
            if appearance == "light" {
                app.buttons["chat.attachment.save"].tap()
                XCTAssertTrue(app.buttons["Save to Files"].waitForExistence(timeout: 5)
                              && app.buttons["Save to Photos"].exists, "Save goes to Files or Photos")
                save("feed-files-5-save", app)
                app.buttons["Save to Files"].tap()
                // The system's file picker; leaving it saves nothing.
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.waitForExistence(timeout: 5) { cancel.tap() }
            }
            app.terminate()
        }
    }

    @MainActor private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance,
                               "-loopdy.home.opens-chat", "YES"]
        app.launch()
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_BOARD_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
