import XCTest

/// The chat's loaders on demo data (`-test-loader-chat`): a live run of tools
/// with its unfolded steps, a finished turn's summary, a card streaming in, a
/// picture being made, and a run paused on the person.
/// Set BIGHELP_LOADER_EVIDENCE (TEST_RUNNER_…) to a folder to save screenshots.
final class ChatLoaderUITests: BighelpUITestCase {
    @MainActor
    func testChatWorkCardsAndPicturesUseTheSharedLoaders() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))

            // A card on its way is a skeleton of a card, and a picture being
            // made glows; neither shows code or a made-up progress number.
            let card = app.descendants(matching: .any)["chat.card.pending"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertEqual(card.label, "Making a card")
            XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "loopdy-card")).firstMatch.exists)
            let picture = app.descendants(matching: .any)["image-generating"].firstMatch
            reveal(picture, in: timeline)
            XCTAssertTrue(picture.exists)
            XCTAssertEqual(picture.value as? String ?? "", "")
            save("loader-chat-tail-\(appearance)", app)

            // The live run says what it's doing now, counts its steps and
            // lists them as they happen.
            let live = trail(in: app, labelPrefix: "Browsing the web…")
            reveal(live, in: timeline)
            XCTAssertTrue(live.label.contains("2 steps"), live.label)
            XCTAssertEqual(live.value as? String, "Expanded")
            save("loader-chat-live-\(appearance)", app)
            let finishedStep = app.buttons["chat.activity.loader-t4"]
            let runningStep = app.buttons["chat.activity.loader-t5"]
            XCTAssertTrue(finishedStep.waitForExistence(timeout: 5))
            XCTAssertTrue(finishedStep.label.hasPrefix("Opened stays.example"), finishedStep.label)
            XCTAssertTrue(runningStep.label.hasPrefix("Browsing the web…"), runningStep.label)
            save("loader-chat-live-steps-\(appearance)", app)
            // A step still unfolds its full details in place.
            runningStep.tap()
            XCTAssertEqual(runningStep.value as? String, "Expanded")
            runningStep.tap()

            // The finished turn settles into one line: its real time and steps.
            let fold = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Worked for 14s")).firstMatch
            reveal(fold, in: timeline)
            XCTAssertTrue(fold.label.contains("3 steps"), fold.label)
            XCTAssertEqual(fold.value as? String, "Collapsed")
            fold.tap()
            XCTAssertEqual(fold.value as? String, "Expanded")
            let thought = app.buttons["chat.activity.loader-r1"]
            XCTAssertTrue(thought.waitForExistence(timeout: 5))
            XCTAssertEqual(thought.label, "Thought for 2s")
            // A finished folder says what it did, never "Done".
            let doneTrail = trail(in: app, labelPrefix: "Searched the web, browsed the web, wrote Kyoto plan.md")
            XCTAssertTrue(doneTrail.waitForExistence(timeout: 5))
            XCTAssertTrue(doneTrail.label.contains("3 steps"), doneTrail.label)
            doneTrail.tap()
            XCTAssertTrue(app.buttons["chat.activity.loader-t1"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["chat.activity.loader-t1"].label.hasPrefix("Searched the web"))
            save("loader-chat-done-expanded-\(appearance)", app)
            app.terminate()
        }
    }

    /// Files an agent sent that haven't reached the phone yet show as loading
    /// tiles, never as raw file lines or "Loading name…" text.
    @MainActor
    func testFilesOnTheirWayShowAsLoadingTiles() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            let tiles = app.descendants(matching: .any)["chat.message-attachments.loading"].firstMatch
            XCTAssertTrue(tiles.waitForExistence(timeout: 10))
            reveal(tiles, in: timeline)
            XCTAssertEqual(tiles.label, "Loading 2 files")
            for text in ["MEDIA:", "Loading Kyoto plan.pdf", "/demo/"] {
                XCTAssertFalse(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", text)).firstMatch.exists,
                               text)
            }
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@",
                                                             "Here's the room and your plan.")).firstMatch.exists)
            save("loader-chat-files-\(appearance)", app)
            app.terminate()
        }
    }

    /// Touch and hold a picture in the chat to copy it or save it, without
    /// opening it first.
    @MainActor
    func testTouchAndHoldAPictureToCopyOrSaveIt() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            let photo = app.buttons["Preview gion-street.png"].firstMatch
            XCTAssertTrue(photo.waitForExistence(timeout: 10))
            reveal(photo, in: timeline)
            photo.press(forDuration: 1.2)
            let copy = app.buttons["Copy"].firstMatch
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Save to Photos"].firstMatch.exists)
            save("loader-chat-photo-menu-\(appearance)", app)
            copy.tap()
            XCTAssertFalse(copy.waitForExistence(timeout: 1))
            app.terminate()
        }
    }

    /// A run paused on the person says so, in the warning color, instead of
    /// shimmering as if the agent were busy.
    @MainActor
    func testARunWaitingOnThePersonSaysSo() throws {
        let app = launch(appearance: "light", extra: ["-test-loader-chat-waiting"])
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let waiting = trail(in: app, labelPrefix: "Waiting for your secure input")
        reveal(waiting, in: timeline)
        XCTAssertTrue(waiting.label.contains("3 steps"), waiting.label)
        save("loader-chat-waiting-light", app)
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-loader-chat", "-loopdy.chat.foldCompletedTurns", "YES",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func trail(in app: XCUIApplication, labelPrefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                         "chat.work-trail.", labelPrefix)).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in timeline: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            timeline.swipeDown()
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_LOADER_EVIDENCE"] else { return }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(device)-\(name).png"))
    }
}
