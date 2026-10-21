import XCTest

/// Settings › Notifications › Channels on the demo data. Demo mode reports a few made-up channels.
/// Set BIGHELP_CHANNELS_EVIDENCE (TEST_RUNNER_BIGHELP_CHANNELS_EVIDENCE) to a folder to save screenshots.
final class NotificationChannelsUITests: BighelpUITestCase {
    @MainActor
    func testChannelsLight() throws { try exercise(appearance: "light") }

    @MainActor
    func testChannelsDark() throws { try exercise(appearance: "dark") }

    @MainActor
    private func exercise(appearance: String) throws {
        let app = makeApp()
        // Each UI test starts with fresh settings; launch arguments would pin the values the taps change.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.notifications", in: app).tap()

        let page = app.descendants(matching: .any)["settings.notifications"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let all = app.buttons["settings.notifications.channels.all"].firstMatch
        for _ in 0..<8 where !(all.exists && all.isHittable) { page.swipeUp() }
        XCTAssertTrue(all.waitForExistence(timeout: 5), "Channels is on the Notifications page")
        XCTAssertTrue(all.isSelected, "Every channel is the default")
        let only = app.buttons["settings.notifications.channels.bighelp"].firstMatch
        let choose = app.buttons["settings.notifications.channels.choose"].firstMatch
        XCTAssertFalse(only.isSelected)
        XCTAssertFalse(app.switches["settings.notifications.channels.other"].exists, "No switches until Choose")

        only.tap()
        XCTAssertTrue(only.isSelected)
        XCTAssertFalse(all.isSelected)

        choose.tap()
        XCTAssertTrue(choose.isSelected)
        let imessage = app.switches["settings.notifications.channels.channel.imsg"].firstMatch
        XCTAssertTrue(imessage.waitForExistence(timeout: 8), "The computer's channels show under Choose")
        XCTAssertTrue(app.switches["settings.notifications.channels.channel.telegram"].exists)
        let other = app.switches["settings.notifications.channels.other"].firstMatch
        XCTAssertEqual(imessage.value as? String, "On", "Choose starts with every channel on")

        reveal(imessage, in: page)
        imessage.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(imessage.value as? String, "Off")
        reveal(other, in: page)
        XCTAssertTrue(other.exists, "New channels sits under the list")
        other.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(other.value as? String, "Off")
        let telegram = app.switches["settings.notifications.channels.channel.telegram"].firstMatch
        XCTAssertEqual(telegram.value as? String, "On", "New channels changes only channels not in the list")
        XCTAssertEqual(imessage.value as? String, "Off")
        reveal(all, in: page, above: true)
        save("channels-choose-\(appearance)", app)

        // The picks survive a relaunch.
        app.terminate()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.notifications", in: app).tap()
        let chooseAgain = app.buttons["settings.notifications.channels.choose"].firstMatch
        for _ in 0..<8 where !(chooseAgain.exists && chooseAgain.isHittable) { page.swipeUp() }
        XCTAssertTrue(chooseAgain.waitForExistence(timeout: 5))
        XCTAssertTrue(chooseAgain.isSelected)
        let imessageAgain = app.switches["settings.notifications.channels.channel.imsg"].firstMatch
        XCTAssertTrue(imessageAgain.waitForExistence(timeout: 5))
        XCTAssertEqual(imessageAgain.value as? String, "Off")
    }

    /// Scrolls until the row is clear of the header and the bottom edge, so a tap lands on it. A List drops rows
    /// far off screen; `above` says which way to look for one that isn't there yet.
    @MainActor
    private func reveal(_ element: XCUIElement, in page: XCUIElement, above: Bool = false) {
        for _ in 0..<8 {
            guard element.exists else {
                if above { page.swipeDown(velocity: .slow) } else { page.swipeUp(velocity: .slow) }
                continue
            }
            let frame = element.frame, window = page.frame
            if element.isHittable, frame.minY > window.minY + 160, frame.maxY < window.maxY - 60 { return }
            if frame.midY < window.midY { page.swipeDown() } else { page.swipeUp() }
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CHANNELS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
