import XCTest
import CoreFoundation

final class ChatStreamingAnchorUITests: BighelpUITestCase {
    @MainActor
    func testSendingFromHistoryReturnsToTheLiveAnswer() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-companion-disabled", "-test-tool-disclosure-scroll", "-test-canvas-stream"]
        app.launchEnvironment["BIGHELP_CANVAS_RESUME_NOTIFICATION"] = "app.loopdy.fixture.send-from-history.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }
        let timeline = app.tables["chat.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        let latest = app.buttons["Return to latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        let input = app.textViews["Message"]
        input.tap()
        input.typeText("Send from older history")
        app.buttons["chat.send"].tap()
        let answer = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Stream line 20:")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 8))
        XCTAssertTrue(latest.waitForNonExistence(timeout: 3), "An explicit send must resume following the response.")
        XCTAssertTrue(answer.isHittable)
    }

    @MainActor
    func testConsecutiveLargeToolsKeepMainThreadResponsive() throws {
        try exerciseToolStream(long: true, expanded: true, backgroundChat: true, consecutiveTools: true)
    }

    @MainActor
    func testShortToolStreamKeepsMainThreadResponsive() throws {
        try exerciseToolStream(long: false, expanded: false)
    }

    @MainActor
    func testSecondToolTurnRetainsEarlierMessagesAndReturnsToLatest() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-companion-disabled", "-test-tool-stream", "-test-tool-stream-two-turns"]
        app.launch()
        let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
            ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        confirmNewChatPicker(in: app)
        let input = app.textViews["Message"]
        for number in 1...2 {
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            input.tap()
            input.typeText("Tool conversation turn \(number)")
            app.buttons["chat.send"].tap()
            let complete = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "TOOL STREAM COMPLETE \(number)")).firstMatch
            XCTAssertTrue(complete.waitForExistence(timeout: 15))
        }
        let timeline = app.tables["chat.timeline"]
        let firstHuman = app.textViews["You: Tool conversation turn 1"]
        for _ in 0..<15 where !firstHuman.isHittable { timeline.swipeDown(velocity: .fast) }
        XCTAssertTrue(firstHuman.isHittable, "The earlier turn must remain reachable after row migration")
        let latest = app.buttons["Return to latest messages"]
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        latest.tap()
        let secondFinal = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "TOOL STREAM COMPLETE 2")).firstMatch
        XCTAssertTrue(secondFinal.waitForExistence(timeout: 5))
        XCTAssertTrue(secondFinal.isHittable)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "second-tool-turn-returned-to-latest"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func exerciseToolStream(long: Bool, expanded: Bool, backgroundChat: Bool = false,
                                    interactDuringStream: Bool = false, consecutiveTools: Bool = false,
                                    inspectFullText: Bool = false) throws {
        let app = makeApp()
        let completionName = "app.loopdy.fixture.tool-stream.\(UUID().uuidString)"
        let streamed = XCTestExpectation(description: "Measured tool stream completed")
        let observer = Unmanaged.passRetained(streamed).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            Unmanaged<XCTestExpectation>.fromOpaque(observer).takeUnretainedValue().fulfill()
        }, completionName as CFString, nil, .deliverImmediately)
        defer {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(completionName as CFString), nil)
            Unmanaged<XCTestExpectation>.fromOpaque(observer).release()
        }
        app.launchEnvironment["BIGHELP_TOOL_STREAM_COMPLETION_NOTIFICATION"] = completionName
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-companion-disabled", "-test-tool-stream"]
        if long { app.launchArguments.append("-test-tool-stream-long") }
        if expanded { app.launchArguments.append("-test-tool-stream-expanded") }
        if backgroundChat { app.launchArguments.append("-test-two-chat-stream") }
        if consecutiveTools { app.launchArguments.append("-test-tool-stream-consecutive") }
        if inspectFullText { app.launchArguments.append("-test-tool-reader") }
        app.launch()
        let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
            ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        confirmNewChatPicker(in: app)
        let input = app.otherElements["chat.composer-shell"].textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Exercise growing tool conversation")
        app.buttons["chat.send"].tap()
        if interactDuringStream {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            input.tap()
            guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else {
                XCTFail("The composer must accept focus while both chats are running.")
                return
            }
            input.typeText("A draft while two chats work")
            XCTAssertEqual(input.value as? String, "A draft while two chats work")
            let timeline = app.tables["chat.timeline"]
            timeline.swipeDown(velocity: .fast)
            let latest = app.buttons["Return to latest messages"]
            XCTAssertTrue(latest.waitForExistence(timeout: 3), "Scrolling into history must expose Return to Latest")
            if latest.exists { latest.tap() }
        }
        // Do not repeatedly snapshot every lazy historical text view while
        // measuring frame pacing. The app signals completion without AX work;
        // inspect the real rendered completion and metrics immediately afterward.
        XCTAssertEqual(XCTWaiter.wait(for: [streamed], timeout: 45), .completed,
                       "Interleaved tool/text stream must complete without locking up")
        let complete = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "TOOL STREAM COMPLETE")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        guard complete.exists else { return }
        let text = complete.label
        if backgroundChat {
            XCTAssertTrue(text.contains("BACKGROUND_CHAT_UPDATES=100"))
        }
        if interactDuringStream {
            XCTAssertEqual(input.value as? String, "A draft while two chats work")
        }
        let report = XCTAttachment(string: text)
        report.name = "tool-stream-\(long ? "long" : "short")-\(expanded ? "expanded" : "collapsed")"
        report.lifetime = .keepAlways
        add(report)
        let pattern = #"FRAME_GAP_MS=(\d+) ELAPSED_SECONDS=(\d+) FRAME_COUNT=(\d+) FRAME_GAP_P95_MS=(\d+) MAIN_QUEUE_MAX_MS=(\d+) ANSWER_QUEUE_P95_MS=(\d+) ANSWER_QUEUE_COUNT=(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        func number(_ index: Int) throws -> Int {
            let range = try XCTUnwrap(Range(match.range(at: index), in: text))
            return try XCTUnwrap(Int(text[range]))
        }
        XCTAssertGreaterThan(try number(3), 10, "Measure actual rendered frames")
        XCTAssertLessThan(try number(2), 30, "Work must not accumulate faster than it can be presented")
        XCTAssertGreaterThan(try number(7), 10, "Measure actual scheduling throughout the growing answer")
        if !interactDuringStream {
            // XCTest's interaction queries enumerate the expanded transcript's
            // accessibility tree on main. Keep its timing report, but enforce
            // the unchanged budgets in the separate no-polling benchmark.
            XCTAssertLessThan(try number(1), 500, "The app must not stall its main thread for half a second")
            XCTAssertLessThan(try number(5), 250, "Expanded tool work must keep the main queue responsive")
            XCTAssertLessThan(try number(6), 50, "Growing text must not repeatedly stall the main queue")
        }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = (report.name ?? "tool-stream") + "-completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        if inspectFullText {
            // Completed work folds after the stream ends. Open that real
            // disclosure before searching inside its virtualized tool rows.
            let completedTurn = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.completed-turn:")).firstMatch
            for _ in 0..<8 {
                if completedTurn.exists && completedTurn.isHittable { break }
                app.tables["chat.timeline"].swipeDown(velocity: .fast)
            }
            XCTAssertTrue(completedTurn.exists && completedTurn.isHittable)
            guard completedTurn.exists && completedTurn.isHittable else { return }
            completedTurn.tap()
            let fullButtons = app.buttons.matching(NSPredicate(format: "label == %@", "View full details"))
            var visibleFullButton: XCUIElement?
            for _ in 0..<8 {
                visibleFullButton = fullButtons.allElementsBoundByIndex.first(where: { $0.isHittable })
                if visibleFullButton != nil { break }
                app.tables["chat.timeline"].swipeUp()
            }
            let full = try XCTUnwrap(visibleFullButton)
            full.tap()
            XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Copy all"].exists)
            let firstPage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Verified canonical row and stable identity")).firstMatch
            XCTAssertTrue(firstPage.waitForExistence(timeout: 5))
            let lastPage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "END OF COMPLETE TOOL RESULT")).firstMatch
            for _ in 0..<15 {
                if lastPage.exists && lastPage.isHittable { break }
                app.scrollViews.firstMatch.swipeUp(velocity: .fast)
            }
            XCTAssertTrue(lastPage.exists && lastPage.isHittable, "The full reader must render the final source page")
            app.buttons["Copy all"].tap()
            app.buttons["Done"].tap()
            XCTAssertTrue(app.tables["chat.timeline"].waitForExistence(timeout: 5))
            input.tap()
            input.press(forDuration: 1)
            let paste = app.menuItems["Paste"].exists ? app.menuItems["Paste"] : app.buttons["Paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 3))
            paste.tap()
            let copied = try XCTUnwrap(input.value as? String)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
            let marker = try XCTUnwrap(object["zz_end"] as? String)
            let index = try XCTUnwrap(Int(try XCTUnwrap(marker.split(separator: " ").last)))
            let expected = "{\"files\":[" + (0..<32).map { "{\"path\":\"source/feature-\(index)/file-\($0).swift\",\"result\":\"Verified canonical row and stable identity\"}" }.joined(separator: ",") + "],\"zz_end\":\"END OF COMPLETE TOOL RESULT \(index)\"}"
            XCTAssertEqual(copied, expected, "Copy all must preserve the complete unformatted source")
        }
    }

    @MainActor
    func testReadingHistoryDuringStreamStaysPutUntilReturnToLatest() {
        let app = makeApp()
        let resumeSignal = "app.loopdy.fixture.canvas-resume.\(UUID().uuidString)"
        app.launchEnvironment["BIGHELP_CANVAS_RESUME_NOTIFICATION"] = resumeSignal
        func resumeStream() {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(resumeSignal as CFString), nil, nil, true)
        }
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-companion-disabled", "-test-canvas-stream"]
        app.launch()
        let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
            ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        confirmNewChatPicker(in: app)
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Keep my reading position")
        app.buttons["chat.send"].tap()
        let response = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Stream line 20:")).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 8))
        let timeline = app.tables["chat.timeline"]
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        // V3 message text is a selectable native UITextView, not StaticText.
        let human = app.textViews["You: Keep my reading position"]
        XCTAssertTrue(human.waitForExistence(timeout: 3))
        let readerY = human.frame.minY
        let before = response.label.count
        resumeStream()
        let grew = NSPredicate { _, _ in response.label.count > before }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: grew, object: nil)], timeout: 4), .completed)
        XCTAssertGreaterThan(response.label.count, before)
        XCTAssertEqual(human.frame.minY, readerY, accuracy: 2,
                       "A live answer must not pull a reader away from history.")
        let returnButton = app.buttons["Return to latest messages"]
        XCTAssertTrue(returnButton.exists)
        returnButton.tap()
        resumeStream()
        let finished = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Stream line 100:")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 15))
        XCTAssertTrue(returnButton.waitForNonExistence(timeout: 3), "The settled tail must clear Return to Latest")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "stream-completed-after-return-to-latest"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testGrowingResponseDoesNotJumpDownWhileFollowingTail() {
        let app = makeApp()
        let resumeSignal = "app.loopdy.fixture.canvas-samples.\(UUID().uuidString)"
        app.launchEnvironment["BIGHELP_CANVAS_RESUME_NOTIFICATION"] = resumeSignal
        app.launchEnvironment["BIGHELP_CANVAS_SAMPLE_EACH_BATCH"] = "YES"
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-companion-disabled", "-test-canvas-stream", "-test-canvas-hold-open"]
        app.launch()
        defer { app.terminate() }
        let newChat = chatNewChatButton(in: app).waitForExistence(timeout: 5)
            ? chatNewChatButton(in: app) : app.buttons["root.new-chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        confirmNewChatPicker(in: app)
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Grow a response")
        app.buttons["chat.send"].tap()
        let response = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "CANVAS STREAM START")).firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 5))
        var textLengths = Set<Int>()
        var samples: [(CGFloat, CGFloat)] = []
        for batch in 1...20 {
            let reachedBatch = NSPredicate { _, _ in response.label.contains("Stream line \(batch * 5):") }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reachedBatch, object: nil)], timeout: 4), .completed)
            textLengths.insert(response.label.count)
            let frame = response.frame
            samples.append((frame.minY, frame.height))
            if batch < 20 {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                    CFNotificationName(resumeSignal as CFString), nil, nil, true)
            }
        }
        let evidence = XCTAttachment(string: samples.map { "\($0.0),\($0.1)" }.joined(separator: "\n"))
        evidence.name = "growing-response-positions"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertGreaterThan(textLengths.count, 5, "Observe actual ongoing text growth.")
        let liveTail = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Sending. Avery Park is working.")
        ).firstMatch
        XCTAssertTrue(liveTail.exists)
        XCTAssertGreaterThan(liveTail.frame.minY, app.otherElements["chat.header-surface"].frame.maxY)
        XCTAssertLessThanOrEqual(liveTail.frame.maxY + 62, input.frame.minY,
                                "The actual live tail and its breathing room stay above the composer.")
        for (previous, current) in zip(samples, samples.dropFirst()) where current.1 >= previous.1 {
            XCTAssertLessThanOrEqual(current.0 - previous.0, 4,
                "A growing response must not jump downward against the upward stream.")
        }
    }

}
