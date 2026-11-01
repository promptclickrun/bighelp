import XCTest

/// The text size out of the box (#729), on the demo data: a chat, Settings › Appearance › Text and
/// buttons and Settings › Appearance › Chat layout, in light and dark. Screenshots are kept with the
/// run and saved to `BIGHELP_SCREENSHOT_DIR` when it's set. For the sizes before #729, run it again
/// with `BIGHELP_UI_EXTRA_ARGS="-bighelp.appearance.text-size 0"` (Medium, the old Default).
final class TextSizeDefaultUITests: BighelpUITestCase {
    @MainActor
    func testTextSizeOutOfTheBoxInLight() throws {
        try textSizeOutOfTheBox(appearance: "light")
    }

    @MainActor
    func testTextSizeOutOfTheBoxInDark() throws {
        try textSizeOutOfTheBox(appearance: "dark")
    }

    /// A run with a size pinned by `BIGHELP_UI_EXTRA_ARGS` isn't the default.
    private var pinsTextSize: Bool {
        ProcessInfo.processInfo.environment["BIGHELP_UI_EXTRA_ARGS"]?.contains("-bighelp.appearance.text-size") == true
    }

    @MainActor
    private func textSizeOutOfTheBox(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance]
        app.launch()
        let name = "text-size-\(pinsTextSize ? "pinned" : "default")"

        let chat = app.buttons["session.row.demo-finance"].firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 15))
        chat.tap()
        XCTAssertTrue(app.buttons["chat.menu"].firstMatch.waitForExistence(timeout: 10), "The chat opened")
        XCTAssertTrue(app.descendants(matching: .any)["chat.message.inline-selection"].firstMatch
            .waitForExistence(timeout: 10), "The chat shows its messages")
        capture("\(name)-chat-\(appearance)", in: app)

        openSettings(in: app)
        settingsRow("settings.themes", in: app).tap()
        let studio = app.descendants(matching: .any)["appearance.studio"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        let textSize = app.sliders["appearance.text-size"].firstMatch
        let buttonSize = app.segmentedControls["appearance.button-size"].firstMatch
        // Scroll until the whole Text and buttons section sits inside the screen, not on its edge.
        let bottom = app.windows.firstMatch.frame.maxY
        for _ in 0..<10 where !buttonSize.exists || !buttonSize.isHittable || buttonSize.frame.maxY > bottom - 160 {
            studio.swipeUp()
        }
        XCTAssertTrue(textSize.isHittable)
        if !pinsTextSize { XCTAssertEqual(textSize.value as? String, "Default", "Default is the size out of the box") }
        capture("\(name)-appearance-\(appearance)", in: app)

        let chatLayout = app.buttons["settings.appearance.chat-layout"].firstMatch
        for _ in 0..<6 where !chatLayout.exists || !chatLayout.isHittable { studio.swipeUp() }
        chatLayout.tap()
        let messageSize = app.sliders["chat-layout.text-size"].firstMatch
        XCTAssertTrue(messageSize.waitForExistence(timeout: 5))
        // Messages size on top of the app's text size, so their own default stays.
        XCTAssertEqual(messageSize.value as? String, "Small")
        capture("\(name)-chat-layout-\(appearance)", in: app)
    }

    /// Kept with the run; also saved to `BIGHELP_SCREENSHOT_DIR` when it's set.
    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
        }
    }
}
