import XCTest

/// An agent's screen in demo mode, with the real controls: the profile's Screen tab,
/// Open screen, Take control, the keyboard and pointer buttons, Hand back and Close.
/// Demo mode's screen is a small RFB server in the app, so the real client draws it.
/// Set BIGHELP_BOT_SCREEN_EVIDENCE (TEST_RUNNER_BIGHELP_BOT_SCREEN_EVIDENCE) to a folder
/// to save each step in light and dark.
final class BotScreenUITests: BighelpUITestCase {
    @MainActor
    func testWatchTakeControlHandBackAndClose() throws {
        let folder = ProcessInfo.processInfo.environment["BIGHELP_BOT_SCREEN_EVIDENCE"]
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                                   "-loopdy.settings.nerd-mode", "NO", "-loopdy.demo.appearance", appearance]
            app.launch()
            let avatar = app.buttons["agent.hero.avatar"].firstMatch
            XCTAssertTrue(avatar.waitForExistence(timeout: 25))
            avatar.tap()
            XCTAssertTrue(element("agent.profile", in: app).waitForExistence(timeout: 10))

            let screenTab = app.buttons["agent.profile.tab.screen"]
            XCTAssertTrue(screenTab.waitForExistence(timeout: 10), "The demo host has screens")
            let order = ["activity", "approvals", "screen", "schedules", "identity"]
                .map { app.buttons["agent.profile.tab.\($0)"].frame.minX }
            XCTAssertEqual(order, order.sorted(), "Screen is third, between Approvals and Schedules")
            screenTab.tap()
            let preview = app.buttons["agent.screen.preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
            sleep(2) // the first still
            save(folder, "\(appearance)-1-profile-screen", app)

            app.buttons["agent.screen.open"].tap()
            let title = app.staticTexts["screen.viewer.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let takeControl = app.buttons["screen.viewer.take-control"]
            XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
            waitUntil(timeout: 10) { takeControl.isEnabled }
            XCTAssertEqual(title.label, "Avery Park is in control")
            XCTAssertTrue(app.buttons["screen.viewer.close"].exists)
            XCTAssertFalse(app.buttons["screen.viewer.keyboard"].exists, "Watching: no keyboard")
            save(folder, "\(appearance)-2-watching", app)

            takeControl.tap()
            let handBack = app.buttons["screen.viewer.hand-back"]
            XCTAssertTrue(handBack.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "You're in control")
            let keyboard = app.buttons["screen.viewer.keyboard"]
            let pointerMode = app.buttons["screen.viewer.pointer-mode"]
            XCTAssertTrue(keyboard.exists)
            XCTAssertTrue(pointerMode.exists)
            for control in [keyboard, pointerMode, handBack] {
                XCTAssertGreaterThanOrEqual(control.frame.width, 44, "Room for a finger")
                XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            }
            XCTAssertGreaterThanOrEqual(pointerMode.frame.minX - keyboard.frame.maxX, 8, "Apart enough to hit")

            // A tap is a left click where it lands: the demo screen marks it.
            let canvas = element("screen.viewer.canvas", in: app)
            canvas.tap()
            waitUntil(timeout: 5) { Self.showsClickMark(canvas.screenshot().image) }
            // Typing goes to the screen's terminal.
            keyboard.tap()
            let keys = app.keyboards.firstMatch
            XCTAssertTrue(keys.waitForExistence(timeout: 5), "The keyboard shows for typing on the screen")
            // A fresh simulator's first keyboard shows a slide-to-type tip.
            let tip = app.buttons["Continue"].firstMatch
            if tip.waitForExistence(timeout: 2) { tip.tap() }
            for key in ["h", "i"] where keys.keys[key].waitForExistence(timeout: 2) { keys.keys[key].tap() }
            sleep(1)
            save(folder, "\(appearance)-3-in-control", app)
            pointerMode.tap()
            XCTAssertTrue(pointerMode.label.contains("move the view"), pointerMode.label)
            pointerMode.tap()

            handBack.tap()
            XCTAssertTrue(takeControl.waitForExistence(timeout: 5))
            XCTAssertEqual(title.label, "Avery Park is in control")
            XCTAssertFalse(keyboard.exists)

            app.buttons["screen.viewer.close"].tap()
            XCTAssertTrue(preview.waitForExistence(timeout: 5), "Back on the profile")
            XCTAssertFalse(title.exists)
            app.terminate()
        }
    }

    /// The demo screen draws a left click as an Ember (#FF8A7A) dot.
    private static func showsClickMark(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains { index in
            abs(Int(pixels[index]) - 0xFF) < 14 && abs(Int(pixels[index + 1]) - 0x8A) < 14
                && abs(Int(pixels[index + 2]) - 0x7A) < 14
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline, !condition() { usleep(200_000) }
        XCTAssertTrue(condition())
    }

    private func save(_ folder: String?, _ name: String, _ app: XCUIApplication) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
