import XCTest
import CoreFoundation

/// How fast a long chat opens (from the chat list, and from a link the way a notification
/// opens it) and how smoothly it scrolls, on demo data. For comparing two builds on one
/// simulator; the numbers aren't an iPhone's. Set BIGHELP_SPEED (TEST_RUNNER_…) to run.
///
/// The `Realistic` checks use `-test-long-chat` (questions, thinking, tools and Markdown
/// answers; BIGHELP_SPEED_TURNS turns, 300 unless set; BIGHELP_SPEED_HEAVY makes each turn as
/// big as a chat near half a million tokens, `-test-long-chat-heavy`). The app's DEBUG probe
/// (`ChatPerformanceRecorder`) is reset and read with Darwin notifications around each
/// phase, so nothing polls the accessibility tree while it's measured; each reading is
/// written to the app's Documents as `chat-performance-<label>-<n>.json`.
final class ChatLoadSpeedUITests: BighelpUITestCase {
    private static let longChat = "demo-long-transcript"
    private static let realisticChat = "demo-long-chat-1"
    private static var turns: Int {
        ProcessInfo.processInfo.environment["BIGHELP_SPEED_TURNS"].flatMap(Int.init) ?? 300
    }
    private static var isHeavy: Bool { ProcessInfo.processInfo.environment["BIGHELP_SPEED_HEAVY"] != nil }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["BIGHELP_SPEED"] != nil else {
            throw XCTSkip("Speed checks run on request")
        }
    }

    @MainActor
    func testOpeningALongChatFromTheList() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
        measureOpening(app) {
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
        }
    }

    @MainActor
    func testOpeningALongChatFromALink() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
        measureOpening(app) {
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            app.open(URL(string: "loopdy://chat/\(Self.longChat)")!)
        }
    }

    @MainActor
    func testScrollingALongChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-start-long-transcript"]
        app.launch()
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        XCTAssertTrue(latest(in: app).waitForExistence(timeout: 20))
        measureScrolling(timeline)
    }

    /// From tapping the chat in the list until its newest answer shows, then back to the list.
    @MainActor
    func testOpeningALongRealisticChatFromTheList() throws {
        let app = launchRealistic(label: "open")
        let row = app.descendants(matching: .any)["session.row.\(Self.realisticChat)"].firstMatch
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
                options: options) {
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            post(ChatPerformance.reset)
            startMeasuring()
            row.tap()
            XCTAssertTrue(realisticLatest(in: app).waitForExistence(timeout: 30))
            stopMeasuring()
            post(ChatPerformance.read)
            app.open(URL(string: "loopdy://sessions")!)
            XCTAssertTrue(row.waitForExistence(timeout: 20))
        }
    }

    @MainActor
    func testScrollingALongRealisticChat() throws {
        let app = launchRealistic(label: "scroll", opensChat: true)
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        XCTAssertTrue(realisticLatest(in: app).waitForExistence(timeout: 30))
        post(ChatPerformance.reset)
        measureScrolling(timeline)
        post(ChatPerformance.read)
        settle()
    }

    /// Flicks through the chat with real touches but no element queries: a query reads every
    /// row of a long chat into the accessibility tree first, which would change what's measured.
    @MainActor
    func testFlickingThroughALongRealisticChat() throws {
        let app = launchRealistic(label: "flick", opensChat: true)
        Thread.sleep(forTimeInterval: 10)
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        post(ChatPerformance.reset)
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            for _ in 0..<3 { top.press(forDuration: 0.01, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0) }
            stopMeasuring()
            for _ in 0..<3 { bottom.press(forDuration: 0.01, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0) }
        }
        post(ChatPerformance.read)
        settle()
    }

    /// What each key typed in the message box costs while a long chat is open.
    @MainActor
    func testTypingInALongRealisticChat() throws {
        let app = launchRealistic(label: "typing", opensChat: true)
        XCTAssertTrue(realisticLatest(in: app).waitForExistence(timeout: 30))
        let input = app.otherElements["chat.composer-shell"].textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        settle()
        post(ChatPerformance.reset)
        // 60 characters, one key at a time.
        input.typeText("Could you check the vendor invoices for this week, please?!")
        settle()
        post(ChatPerformance.read)
        settle()
        XCTAssertEqual(input.value as? String, "Could you check the vendor invoices for this week, please?!")
    }

    /// A tool turn and a growing answer at the bottom of a long chat.
    @MainActor
    func testStreamingInALongRealisticChat() throws {
        let completionName = "app.loopdy.fixture.tool-stream.\(UUID().uuidString)"
        let streamed = XCTestExpectation(description: "Tool stream completed")
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
        let app = makeApp()
        app.launchEnvironment["BIGHELP_TOOL_STREAM_COMPLETION_NOTIFICATION"] = completionName
        app.launchEnvironment["BIGHELP_PERF_LABEL"] = "stream-\(Self.turns)"
        app.launchArguments = realisticArguments(opensChat: true) + ["-test-tool-stream", "-test-companion-disabled"]
        app.launch()
        XCTAssertTrue(realisticLatest(in: app).waitForExistence(timeout: 30))
        let input = app.otherElements["chat.composer-shell"].textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Run the weekly checks")
        settle()
        post(ChatPerformance.reset)
        app.buttons["chat.send"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [streamed], timeout: 60), .completed)
        post(ChatPerformance.read)
        let complete = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "TOOL STREAM COMPLETE")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        let report = XCTAttachment(string: complete.label)
        report.name = "tool-stream-in-long-chat-\(Self.turns)"
        report.lifetime = .keepAlways
        add(report)
    }

    /// Opens four long chats one after another, reading the app's memory after each.
    @MainActor
    func testOpeningSeveralLongRealisticChatsInARow() throws {
        let app = makeApp()
        app.launchEnvironment["BIGHELP_PERF_LABEL"] = "memory-\(Self.turns)"
        app.launchArguments = realisticArguments(opensChat: false) + ["-test-long-chat-count", "4"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["session.row.\(Self.realisticChat)"].firstMatch
            .waitForExistence(timeout: 20))
        settle()
        post(ChatPerformance.read)
        for index in 1...4 {
            let row = app.descendants(matching: .any)["session.row.demo-long-chat-\(index)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
            XCTAssertTrue(realisticLatest(in: app).waitForExistence(timeout: 30))
            let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
            for _ in 0..<4 { timeline.swipeDown(velocity: .fast) }
            app.open(URL(string: "loopdy://sessions")!)
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            settle()
            post(ChatPerformance.read)
        }
        Thread.sleep(forTimeInterval: 5)
        post(ChatPerformance.read)
        settle()
    }

    private enum ChatPerformance {
        static let reset = "app.loopdy.fixture.chat-performance.reset"
        static let read = "app.loopdy.fixture.chat-performance.read"
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Lets the app finish what the last action started before the next phase.
    private func settle() { Thread.sleep(forTimeInterval: 1.5) }

    @MainActor
    private func measureScrolling(_ timeline: XCUIElement) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            stopMeasuring()
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
        }
    }

    /// From `open` until the chat's newest message shows, then back to the list.
    @MainActor
    private func measureOpening(_ app: XCUIApplication, open: () -> Void) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 5
        let sessions = URL(string: "loopdy://sessions")!
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            startMeasuring()
            open()
            XCTAssertTrue(latest(in: app).waitForExistence(timeout: 20))
            stopMeasuring()
            app.open(sessions)
            XCTAssertTrue(app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
                .waitForExistence(timeout: 20))
        }
    }

    private func latest(in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "settled sentinel 1000")).firstMatch
    }

    private func realisticLatest(in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Long chat sentinel \(Self.turns)")).firstMatch
    }

    private func realisticArguments(opensChat: Bool) -> [String] {
        ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3", "-test-long-chat", "\(Self.turns)",
         "-test-chat-performance-probe"] + (Self.isHeavy ? ["-test-long-chat-heavy"] : [])
            + (opensChat ? ["-start-long-chat"] : [])
    }

    @MainActor
    private func launchRealistic(label: String, opensChat: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchEnvironment["BIGHELP_PERF_LABEL"] = "\(label)-\(Self.turns)"
        app.launchArguments = realisticArguments(opensChat: opensChat)
        app.launch()
        return app
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.opens-chat", "NO"]
        app.launch()
        return app
    }
}
