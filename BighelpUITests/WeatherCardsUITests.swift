import XCTest

/// Issue #96: weather behind cards (`-test-weather-cards`, made-up places).
/// Each scene moves with motion on and holds still with Reduce Motion; a scene
/// this build doesn't know and `none` never move. Scrolling past ten moving
/// cards is measured next to the same chat with plain cards.
///
/// TEST_RUNNER_BIGHELP_WEATHER_EVIDENCE=<folder> saves screenshots there.
/// TEST_RUNNER_BIGHELP_WEATHER_REDUCED=1 says the simulator has Reduce Motion
/// on (it can't be switched from a test).
final class WeatherCardsUITests: BighelpUITestCase {
    private struct Card {
        let place: String
        let scene: String
        var moves: Bool { scene != "hail" && scene != "none" }
    }

    private let cards = [
        Card(place: "Sample Bay", scene: "clear"), Card(place: "Demo Ridge", scene: "partly_cloudy"),
        Card(place: "Testville", scene: "overcast"), Card(place: "Port Example", scene: "rain"),
        Card(place: "Mockford", scene: "thunderstorm"), Card(place: "Placeholder Peak", scene: "snow"),
        Card(place: "Fixture Harbor", scene: "fog"), Card(place: "Gusty Flats", scene: "wind"),
        Card(place: "Drizzle Point", scene: "rain"), Card(place: "Starry Hollow", scene: "clear"),
        Card(place: "Unknown Vale", scene: "hail"), Card(place: "Plain Town", scene: "none"),
    ]

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testEachSceneMovesUnlessReduceMotionIsOn() throws {
        let reduced = environment["BIGHELP_WEATHER_REDUCED"] != nil
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            save("\(appearance)-bottom", app.screenshot())
            // The chat opens at its end; walk up through the cards.
            for (index, card) in cards.enumerated().reversed() {
                bringIntoView(app.cells["message:weather-card-\(index)"], in: timeline)
                let element = cardElement(card, in: app)
                XCTAssertTrue(element.exists && fullyVisible(element, in: timeline), card.place)
                // Let scrolling settle, then compare two moments half a second apart.
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                let first = element.screenshot()
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
                let second = element.screenshot()
                let label = "\(card.place) (\(card.scene)) in \(appearance)"
                if card.moves && !reduced {
                    XCTAssertNotEqual(first.pngRepresentation, second.pngRepresentation, "\(label) should move")
                } else {
                    XCTAssertEqual(first.pngRepresentation, second.pngRepresentation, "\(label) should hold still")
                }
                save("\(appearance)-\(card.scene)-\(card.place.replacingOccurrences(of: " ", with: "-"))", first)
            }
            save("\(appearance)-top", app.screenshot())
            app.terminate()
        }
    }

    /// Ten moving cards, scrolled past quickly, against the same chat with
    /// every background turned off. The simulator's numbers say how the two
    /// compare, not what an iPhone does.
    @MainActor
    func testScrollingPastTenWeatherCards() throws {
        try measureScrolling(plain: false)
    }

    @MainActor
    func testScrollingPastTenPlainCards() throws {
        try measureScrolling(plain: true)
    }

    @MainActor
    private func measureScrolling(plain: Bool) throws {
        let app = launch(appearance: "dark", extra: plain ? ["-test-weather-cards-plain"] : [])
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            // From the end of the chat to its start: past all twelve cards.
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            stopMeasuring()
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(cardElement(cards[11], in: app).exists || cardElement(cards[0], in: app).exists)
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-weather-cards",
                               "-loopdy.home.opens-chat", "YES", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func cardElement(_ card: Card, in app: XCUIApplication) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", " in \(card.place), "))
        // Recycled rows can leave a copy with an empty frame; use the one on screen.
        return matches.allElementsBoundByIndex.first { $0.frame.height > 40 } ?? matches.firstMatch
    }

    /// Drags the chat a measured distance at a time, without a fling, until the
    /// row sits in the middle. Rows report where they are even offscreen.
    @MainActor
    private func bringIntoView(_ cell: XCUIElement, in timeline: XCUIElement) {
        for _ in 0..<12 {
            guard cell.exists else { timeline.swipeDown(velocity: .slow); continue }
            let offset = cell.frame.midY - timeline.frame.midY
            if abs(offset) < 60 { break }
            let distance = max(-300, min(300, offset))
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: 300, thenHoldForDuration: 0.3)
        }
    }

    @MainActor
    private func fullyVisible(_ element: XCUIElement, in timeline: XCUIElement) -> Bool {
        let frame = element.frame
        let bounds = timeline.frame
        // Keep clear of the header and the composer at the edges.
        return frame.height > 40 && frame.minY >= bounds.minY + 100 && frame.maxY <= bounds.maxY - 140
    }

    @MainActor
    private func save(_ name: String, _ screenshot: XCUIScreenshot) {
        guard let folder = environment["BIGHELP_WEATHER_EVIDENCE"] else { return }
        let suffix = environment["BIGHELP_WEATHER_REDUCED"] != nil ? "-reduced" : ""
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)\(suffix).png")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: url)
    }
}
