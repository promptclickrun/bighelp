import XCTest
import UIKit

final class ComposerInteractionUITests: BighelpUITestCase {
    @MainActor
    func testChatComposerActionCentersWithAnEmptyInput() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"
        ]
        app.launch()

        let input = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        let action = app.buttons["chat.voice"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertEqual(
            action.frame.midY,
            input.frame.midY,
            accuracy: 1,
            "The idle voice-mode pill should share the input's vertical center."
        )
        // The pill sits inside the message box, at its end, with nothing else beside the box.
        let field = app.otherElements["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertTrue(field.frame.insetBy(dx: -1, dy: -1).contains(action.frame), "\(action.frame) in \(field.frame)")
        XCTAssertGreaterThan(action.frame.minX, input.frame.minX)
        let attachment = app.buttons["chat.attachment"]
        XCTAssertTrue(attachment.exists)
        XCTAssertEqual(attachment.frame.midY, input.frame.midY, accuracy: 1)
        XCTAssertEqual(attachment.frame.midY, action.frame.midY, accuracy: 1)
        XCTAssertEqual(attachment.frame.size.height, action.frame.size.height, accuracy: 1)
        print("COMPOSER_ALIGNMENT idle input=\(input.frame) plus=\(attachment.frame) voice=\(action.frame)")
        saveComposer("composer-idle-light", app)
        input.tap()
        input.typeText("Hello")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        let toolbar = app.otherElements["chat.composer.editing-controls"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 3))
        XCTAssertTrue(toolbar.frame.contains(send.frame))
        XCTAssertEqual(send.frame.midY, app.buttons["chat.attachment"].frame.midY, accuracy: 1)
        XCTAssertFalse(app.buttons["chat.voice"].exists, "Typing swaps voice mode for Send, in the same place")
        XCTAssertTrue(field.frame.insetBy(dx: -1, dy: -1).contains(send.frame))
        saveComposer("composer-typing-light", app)
    }

    /// #515: once a draft wraps, the expand button stays and the box keeps its width on every key.
    @MainActor
    func testWrappedDraftKeepsTheBoxStillWhileTyping() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"
        ]
        app.launch()
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let field = app.otherElements["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let expand = app.buttons["chat.composer.expand"]
        let text = "Please read the notes from the garden club and write a short summary of the plans for the spring plant sale with every date"
        var wrappedWidth: CGFloat?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
            input.typeText(String(text[index..<next]))
            index = next
            if let width = wrappedWidth {
                XCTAssertTrue(expand.exists, "The expand button stays once the draft wraps")
                XCTAssertEqual(field.frame.width, width, accuracy: 1, "The box keeps its width while typing")
            } else if expand.exists {
                wrappedWidth = field.frame.width
            }
        }
        XCTAssertNotNil(wrappedWidth, "A long draft wraps and offers the expand button")
        saveComposer("composer-wrapped-light", app)
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        XCTAssertFalse(expand.exists, "An empty draft has no expand button")
    }

    /// Expand sits inside the box, in a corner the text keeps free: the text's width is the same with or
    /// without it, no line runs under it, and it still opens the expanded editor. Light and dark.
    /// Set BIGHELP_COMPOSER_EVIDENCE (TEST_RUNNER_…) to save screenshots.
    @MainActor
    func testExpandSitsInsideTheBoxWithoutNarrowingTheText() throws {
        for appearance in ["light", "dark"] {
            try checkExpandInsideTheBox(appearance: appearance)
        }
    }

    @MainActor
    private func checkExpandInsideTheBox(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", appearance
        ]
        app.launch()
        let input = app.textViews["chat.composer.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let field = app.otherElements["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let expand = app.buttons["chat.composer.expand"]
        input.typeText("W")
        let oneLineWidth = input.frame.width
        XCTAssertFalse(expand.exists, "One line has no Expand")

        // One unbroken run of wide letters reaches the text's trailing edge before it wraps. Until Expand
        // shows, its corner (a 20 pt circle and a 4 pt gap) must stay empty: no letter, no caret.
        // Without the kept corner, the last letters before the wrap land in it.
        var typed = 1
        while !expand.exists, typed < 80 {
            input.typeText("WW")
            typed += 2
            XCTAssertEqual(input.frame.width, oneLineWidth, accuracy: 1, "The text keeps its width while typing")
            guard !expand.exists else { break }
            let corner = CGRect(x: input.frame.maxX - 22, y: input.frame.minY + 3, width: 20, height: 14)
            XCTAssertEqual(inkPixels(in: corner, dark: appearance == "dark"), 0,
                           "No text runs into Expand's corner (\(typed) letters)")
        }
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "A wrapped draft offers Expand")
        XCTAssertEqual(input.frame.width, oneLineWidth, accuracy: 1, "Expand appearing leaves the text's width alone")
        XCTAssertTrue(expand.isHittable)
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        // Inside the box (its touch area may reach into the row's margin above it), and never over Send.
        XCTAssertTrue(field.frame.insetBy(dx: 0, dy: -6).contains(expand.frame), "\(expand.frame) in \(field.frame)")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(expand.frame.intersects(send.frame.insetBy(dx: 1, dy: 1)), "Expand never covers Send")
        saveComposer("composer-expand-inside-\(appearance)", app)

        // More lines, then a box that scrolls: the width holds, and Expand moves above Send, clear of the text.
        // Words, not Return: Return may send, depending on the keyboard.
        input.typeText(" then the notes from the garden club, the dates of the spring plant sale, who brings"
            + " the tables, who bakes, and what to do if it rains on the morning of the sale")
        XCTAssertEqual(input.frame.width, oneLineWidth, accuracy: 1, "A tall draft keeps the text's width")
        XCTAssertTrue(expand.isHittable)
        XCTAssertTrue(field.frame.insetBy(dx: 0, dy: -6).contains(expand.frame), "\(expand.frame) in \(field.frame)")
        XCTAssertGreaterThanOrEqual(expand.frame.minX, input.frame.maxX - 1, "A scrolling draft's lines never pass under Expand")
        XCTAssertFalse(expand.frame.intersects(send.frame.insetBy(dx: 1, dy: 1)), "Expand never covers Send")
        saveComposer("composer-expand-tall-\(appearance)", app)

        expand.tap()
        let expanded = app.textViews["chat.composer.expanded.text"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "Expand opens the expanded editor")
        saveComposer("composer-expand-opened-\(appearance)", app)
        app.terminate()
    }

    /// Pixels in `rect` (screen points) that read as text: dark on the light box, light on the dark one.
    @MainActor
    private func inkPixels(in rect: CGRect, dark: Bool) -> Int {
        let image = XCUIScreen.main.screenshot().image
        guard let cgImage = image.cgImage else { return 0 }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = cgImage.cropping(to: pixels) else { return 0 }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let luminance = (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
                + 0.0722 * Double(bytes[index + 2])) / 255
            if dark ? luminance > 0.7 : luminance < 0.35 { count += 1 }
        }
        return count
    }

    @MainActor
    private func saveComposer(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_COMPOSER_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testChatComposerFocusesFromTheFullVisibleInputSurface() throws {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
            "-loopdy.appearance.interface-version", "v3", "-loopdy.demo.appearance", "light"
        ]
        var testedPaddingRegions = 0

        // The box's right end is the voice-mode pill now, so there's no padding there to tap.
        for (index, region) in ["top", "bottom", "left"].enumerated() {
            if index > 0 {
                app.terminate()
                app.launch()
            } else {
                app.launch()
            }

            let shell = app.otherElements["chat.composer-shell"]
            let input = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
            XCTAssertTrue(shell.waitForExistence(timeout: 5))
            XCTAssertTrue(input.waitForExistence(timeout: 5))

            // The native text view reports its own frame while the visible glass
            // input reserves symmetric vertical and horizontal padding. Tap a
            // region outside the native view but inside that visible surface.
            let shellFrame = shell.frame
            let inputFrame = input.frame
            let normalizedPoint: CGPoint?
            switch region {
            case "top":
                let gap = (inputFrame.minY - shellFrame.minY) / shellFrame.height
                normalizedPoint = gap > 0.16
                    ? CGPoint(x: (inputFrame.midX - shellFrame.minX) / shellFrame.width, y: gap * 0.5)
                    : nil
            case "bottom":
                let gap = (shellFrame.maxY - inputFrame.maxY) / shellFrame.height
                normalizedPoint = gap > 0.16
                    ? CGPoint(x: (inputFrame.midX - shellFrame.minX) / shellFrame.width, y: 1 - gap * 0.5)
                    : nil
            case "left", "right":
                let attachment = app.buttons["chat.attachment"]
                let action = app.buttons["chat.voice"]
                let left = max(inputFrame.minX - 8, attachment.frame.maxX + 2)
                let right = min(inputFrame.maxX + 8, action.frame.minX - 2)
                if region == "left", left < inputFrame.minX - 1 {
                    normalizedPoint = CGPoint(
                        x: (left - shellFrame.minX) / shellFrame.width,
                        y: (inputFrame.midY - shellFrame.minY) / shellFrame.height
                    )
                } else if region == "right", right > inputFrame.maxX + 1 {
                    normalizedPoint = CGPoint(
                        x: (right - shellFrame.minX) / shellFrame.width,
                        y: (inputFrame.midY - shellFrame.minY) / shellFrame.height
                    )
                } else {
                    normalizedPoint = nil
                }
            default:
                normalizedPoint = nil
            }

            guard let normalizedPoint else { continue }
            XCTAssertGreaterThan(normalizedPoint.x, 0)
            XCTAssertLessThan(normalizedPoint.x, 1)
            XCTAssertGreaterThan(normalizedPoint.y, 0)
            XCTAssertLessThan(normalizedPoint.y, 1)
            testedPaddingRegions += 1
            shell.coordinate(withNormalizedOffset: CGVector(
                dx: normalizedPoint.x, dy: normalizedPoint.y
            )).tap()
            XCTAssertTrue(
                app.keyboards.firstMatch.waitForExistence(timeout: 2),
                "Tapping the visible \(region) input padding should focus the native composer editor."
            )
        }

        XCTAssertGreaterThanOrEqual(
            testedPaddingRegions,
            2,
            "The composer must expose at least the upper and lower visible input padding regions."
        )
    }
}
