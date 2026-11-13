import XCTest

/// The plus button beside the message box on demo data (#938): a short menu that only adds
/// things to a message, and Drawing, which attaches what was drawn as a picture.
/// Screenshots go to BIGHELP_UI_EVIDENCE (TEST_RUNNER_BIGHELP_UI_EVIDENCE) when set.
final class ChatAttachmentMenuUITests: BighelpUITestCase {
    @MainActor
    func testThePlusMenuOnlyAddsToAMessage() {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            app.buttons["chat.attachment"].firstMatch.tap()

            // A menu's rows are named by their titles. The simulator has no document scanner.
            let rows = ["Camera", "Photo Library", "Files", "Drawing"].map { app.buttons[$0].firstMatch }
            XCTAssertTrue(rows[0].waitForExistence(timeout: 5), "The menu opens at the plus button")
            for row in rows { XCTAssertTrue(row.exists, row.label) }
            for (upper, lower) in zip(rows, rows.dropFirst()) {
                XCTAssertLessThan(upper.frame.midY, lower.frame.midY, "\(upper.label) comes before \(lower.label)")
            }
            XCTAssertFalse(rows[0].isEnabled, "No camera in the simulator")
            // New chat isn't checked by name: the bar's own New chat button is on screen.
            for gone in ["Voice mode", "Change model", "Choose agent", "PDF as pages", "Auto TTS",
                         "Chat controls"] {
                XCTAssertFalse(app.buttons[gone].exists, "\(gone) left the plus menu")
            }
            evidence("menu-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    func testADrawingIsAddedToTheMessageAsAPicture() {
        let app = launch(appearance: "light")
        app.buttons["chat.attachment"].firstMatch.tap()
        let drawing = app.buttons["Drawing"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 5))
        drawing.tap()

        let canvas = app.descendants(matching: .any)["chat.drawing.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8), "Apple's canvas opens")
        let add = app.buttons["chat.drawing.add"].firstMatch
        XCTAssertTrue(add.exists)
        XCTAssertFalse(add.isEnabled, "Nothing to add before a stroke")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "A stroke turns Add on")
        evidence("drawing", app)
        add.tap()

        XCTAssertTrue(canvas.waitForNonExistence(timeout: 5))
        let attached = app.descendants(matching: .any)["chat.draft-attachments"].firstMatch
        XCTAssertTrue(attached.waitForExistence(timeout: 8), "The drawing is on the message")
        XCTAssertTrue(app.staticTexts["1 photo"].firstMatch.exists, "As one picture")
        evidence("drawing-attached", app)

        // Cancel throws a drawing away.
        app.buttons["chat.attachment"].firstMatch.tap()
        app.buttons["Drawing"].firstMatch.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        app.buttons["chat.drawing.cancel"].firstMatch.tap()
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 photo"].firstMatch.waitForExistence(timeout: 5), "Still one picture")
    }

    /// The page is white paper in dark mode too, so its buttons and its ink must stay dark.
    @MainActor
    func testTheDrawingPageReadsInDarkMode() throws {
        let app = launch(appearance: "dark")
        app.buttons["chat.attachment"].firstMatch.tap()
        let drawing = app.buttons["Drawing"].firstMatch
        XCTAssertTrue(drawing.waitForExistence(timeout: 5))
        drawing.tap()
        let canvas = app.descendants(matching: .any)["chat.drawing.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        let cancel = app.buttons["chat.drawing.cancel"].firstMatch
        XCTAssertGreaterThan(try darkShare(of: cancel.screenshot().image), 0.02, "Cancel's words are dark on the page")

        let blank = try darkShare(of: canvas.screenshot().image, band: 0.35...0.65)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        let add = app.buttons["chat.drawing.add"].firstMatch
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: add)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        evidence("drawing-dark", app)
        XCTAssertGreaterThan(try darkShare(of: canvas.screenshot().image, band: 0.35...0.65), blank + 0.001,
                             "The stroke shows on the white page")
        XCTAssertGreaterThan(try darkShare(of: add.screenshot().image), 0.02, "Add reads on the page")
        let palette = try darkShare(of: XCUIScreen.main.screenshot().image, band: 0.86...0.97)
        XCTAssertLessThan(palette, 0.5, "The tool palette is light, like the page")
    }

    /// The share of dark pixels, in a band of the picture's height.
    private func darkShare(of image: UIImage, band: ClosedRange<Double> = 0...1) throws -> Double {
        let source = try XCTUnwrap(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rows = Int(Double(height) * band.lowerBound)..<max(Int(Double(height) * band.upperBound), 1)
        var dark = 0
        for row in rows {
            for column in 0..<width {
                let at = (row * width + column) * 4
                if Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2]) < 300 { dark += 1 }
            }
        }
        return Double(dark) / Double(rows.count * width)
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["chat.attachment"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "chat-attachment-menu-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("chat-attachment-menu-\(name).png"))
    }
}
