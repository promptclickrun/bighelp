import XCTest

/// Text the app places in the message box (Create a goal, Ask, plugin update)
/// must be drawn in the theme's ink, and typing after it must match.
final class ComposerPrefillUITests: BighelpUITestCase {
    @MainActor
    func testPrefilledTextUsesTheThemeInkInDarkMode() {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", "dark"]
        app.launch()
        openRootTab("tab.goals", in: app)
        // Create a goal › Something else.
        let create = app.buttons["board.goals.create.other"]
        XCTAssertTrue(app.descendants(matching: .any)["board.goals"].waitForExistence(timeout: 10))
        // Goals is a List: the row exists once scrolled to.
        for _ in 0..<8 where !(create.exists && create.isHittable) { app.swipeUp() }
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let placed = NSPredicate(format: "value BEGINSWITH %@", "I'd like to set a goal")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: placed, object: editor)], timeout: 8),
                       .completed, "Create a goal fills the message box")
        sleep(1)
        attach("prefill-dark", editor)
        XCTAssertGreaterThan(lightPixels(in: editor), 40, "Pre-filled text must be light on the dark field, not black")

        editor.tap()
        editor.typeText("Run a 10K by spring")
        sleep(1)
        attach("prefill-dark-typed", editor)
        XCTAssertGreaterThan(lightPixels(in: editor), 120, "Typing after pre-filled text keeps the theme's ink")
    }

    /// Pixels bright enough to be light text on a dark field.
    @MainActor
    private func lightPixels(in element: XCUIElement) -> Int {
        guard let image = element.screenshot().image.cgImage else { return 0 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
            if luminance > 190 { count += 1 }
        }
        return count
    }

    @MainActor
    private func attach(_ name: String, _ element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
