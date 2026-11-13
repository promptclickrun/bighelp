import XCTest

/// The person's circle (which opens Settings) sits in the same spot on every root of the home: Bots,
/// Chats, Today and Work, and it's always there after switching. On demo data. Set
/// BIGHELP_MENU_PLACEMENT_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class MenuButtonPlacementUITests: BighelpUITestCase {
    @MainActor
    func testTheCircleSitsInOnePlaceOnEveryRoot() throws {
        let app = launch()
        var frames: [String: CGRect] = [:]
        for (door, name) in [("home.switch.bots", "bots"), ("home.switch.chats", "chats"), ("home.tab.today", "today"),
                             ("home.tab.work", "work"), ("home.tab.conversations", "bots-again")] {
            if name == "bots" || name == "chats" { app.buttons["home.tab.conversations"].firstMatch.tap() }
            app.buttons[door].firstMatch.tap()
            // Let the switch settle before measuring.
            Thread.sleep(forTimeInterval: 1.2)
            let circle = app.buttons["simple-bots.settings"].firstMatch
            XCTAssertTrue(circle.waitForExistence(timeout: 10), "The circle on \(name)")
            frames[name] = circle.frame
            save("circle-\(name)", app)
        }
        let expected = try XCTUnwrap(frames["bots"])
        for (name, frame) in frames.sorted(by: { $0.key < $1.key }) {
            print("Circle \(name): \(frame)")
            XCTAssertEqual(frame.midX, expected.midX, accuracy: 1, "The circle moves sideways on \(name): \(frame) vs \(expected)")
            XCTAssertEqual(frame.midY, expected.midY, accuracy: 1, "The circle moves up or down on \(name): \(frame) vs \(expected)")
        }
    }

    @MainActor
    func testBotsAlwaysHasTheCircleAfterChats() throws {
        let app = launch()
        for round in 1...12 {
            app.buttons["home.switch.chats"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["chats.inbox"].firstMatch.waitForExistence(timeout: 10),
                          "Chats, round \(round)")
            app.buttons["home.switch.bots"].firstMatch.tap()
            let circle = app.buttons["simple-bots.settings"].firstMatch
            let shown = circle.waitForExistence(timeout: 5) && circle.isHittable
            if !shown { save("bots-missing-circle-\(round)", app) }
            XCTAssertTrue(shown, "The circle on Bots after Chats, round \(round)")
        }
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.landing", "bots"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].firstMatch.waitForExistence(timeout: 20))
        return app
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MENU_PLACEMENT_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
