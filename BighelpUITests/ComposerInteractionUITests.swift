import XCTest
import UIKit

final class ComposerInteractionUITests: BighelpUITestCase {
    @MainActor
    func testChatPillAndNewChatKeepChromeInPlace() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat",
                                   "-bighelp.settings.simple-bots", "NO", "-loopdy.demo.appearance", appearance]
            app.launch()
            let identity = app.buttons["chat.identity"]
            let input = app.textViews["chat.composer.text"]
            let field = app.otherElements["chat.composer.field"]
            XCTAssertTrue(identity.waitForExistence(timeout: 10))
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            let headerFrame = identity.frame
            let fieldFrame = field.frame
            XCTAssertLessThanOrEqual(headerFrame.height, 54)
            XCTAssertLessThan(headerFrame.width, app.frame.width * 0.75)
            saveComposer("chat-pill-\(appearance)", app)

            chatNewChatButton(in: app).tap()
            confirmNewChatPicker(in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertEqual(identity.frame.midY, headerFrame.midY, accuracy: 1)
            XCTAssertEqual(field.frame.midY, fieldFrame.midY, accuracy: 1)
            input.tap()
            input.typeText("A draft in the new chat")
            XCTAssertEqual(input.value as? String, "A draft in the new chat")
            saveComposer("new-chat-draft-\(appearance)", app)
            app.terminate()
        }
    }

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

    /// #515: once Expand shows, it stays and the box keeps its width on every key.
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
        let expand = app.buttons["chat.composer.expand-rail"]
        let text = "Please read the notes from the garden club and write a short summary of the plans for the spring plant sale with every date, who brings the tables and what to do if it rains"
        var shownWidth: CGFloat?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
            input.typeText(String(text[index..<next]))
            index = next
            if let width = shownWidth {
                XCTAssertTrue(expand.exists, "Expand stays once the draft has three lines")
                XCTAssertEqual(field.frame.width, width, accuracy: 1, "The box keeps its width while typing")
            } else if expand.exists {
                shownWidth = field.frame.width
            }
        }
        XCTAssertNotNil(shownWidth, "A long draft offers Expand")
        saveComposer("composer-wrapped-light", app)
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
        XCTAssertTrue(input.waitForExistence(timeout: 2))
        XCTAssertTrue(expand.waitForNonExistence(timeout: 3), "An empty draft has no Expand")
    }

    /// #728: Expand is a small rail centered above the message box, shown only once the draft has
    /// three lines. The box keeps its place and size when it comes and goes, the text uses the box's
    /// full width, and a tap opens the expanded editor. Light and dark.
    /// Set BIGHELP_COMPOSER_EVIDENCE (TEST_RUNNER_…) to save screenshots.
    @MainActor
    func testExpandRailShowsAboveTheBoxFromThreeLines() throws {
        for appearance in ["light", "dark"] {
            try checkExpandRail(appearance: appearance)
        }
    }

    @MainActor
    private func checkExpandRail(appearance: String) throws {
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
        let rail = app.buttons["chat.composer.expand-rail"]
        input.typeText("W")
        // The text view is as tall as its lines (the box's minimum height is around it).
        let lineHeight = input.frame.height
        func lines() -> Int { Int((input.frame.height / lineHeight).rounded()) }
        let boxWidth = field.frame.width
        let boxBottom = field.frame.maxY
        func checkBoxStill(_ step: String) {
            XCTAssertEqual(field.frame.width, boxWidth, accuracy: 1, "The box keeps its width (\(step))")
            XCTAssertEqual(field.frame.maxY, boxBottom, accuracy: 1, "The box stays in place (\(step))")
        }
        XCTAssertFalse(rail.exists, "One line has no Expand")

        // One unbroken run of wide letters wraps by letter, so the first line fills to the box's
        // trailing edge. The old Expand kept that corner (a 20 pt circle and a 4 pt gap) empty.
        var typed = 1
        while lines() < 2, typed < 80 {
            input.typeText("W")
            typed += 1
        }
        XCTAssertEqual(lines(), 2)
        let corner = CGRect(x: input.frame.maxX - 22, y: input.frame.minY + 3, width: 20, height: 14)
        XCTAssertGreaterThan(inkPixels(in: corner, dark: appearance == "dark"), 0,
                             "The first line runs to the box's trailing edge")
        XCTAssertFalse(rail.exists, "Two lines have no Expand")
        checkBoxStill("two lines")
        saveComposer("composer-expand-rail-2-lines-\(appearance)", app)

        // Words, not Return: Return may send, depending on the keyboard.
        let words = ("then the notes from the garden club, the dates of the spring plant sale, who brings the tables,"
            + " who bakes, and what to do if it rains on the morning of the sale").split(separator: " ")
        // The words come round again: an iPad's wide box takes more of them than an iPhone's.
        var nextWord = 0
        func type(untilLines target: Int) {
            var typedWords = 0
            while lines() < target, typedWords < 120 {
                input.typeText(" " + words[nextWord % words.count])
                nextWord += 1
                typedWords += 1
                if lines() < 3 {
                    XCTAssertFalse(rail.exists, "No Expand under three lines")
                }
            }
            XCTAssertGreaterThanOrEqual(lines(), target)
        }
        type(untilLines: 3)
        XCTAssertTrue(rail.waitForExistence(timeout: 3), "Three lines offer Expand")
        checkBoxStill("Expand shows")
        XCTAssertTrue(rail.isHittable)
        XCTAssertGreaterThanOrEqual(rail.frame.width, 44)
        XCTAssertGreaterThanOrEqual(rail.frame.height, 44)
        XCTAssertEqual(rail.frame.midX, field.frame.midX, accuracy: 1, "Centered over the box")
        XCTAssertLessThanOrEqual(rail.frame.maxY, field.frame.minY + 0.5, "Above the box, never over its text")
        XCTAssertLessThan(field.frame.minY - rail.frame.maxY, 2, "Right above the box")
        XCTAssertEqual(rail.label, "Expand")

        type(untilLines: 4)
        XCTAssertTrue(rail.exists, "Four lines keep Expand")
        checkBoxStill("four lines")
        saveComposer("composer-expand-rail-4-lines-\(appearance)", app)

        // Back under three lines, Expand goes.
        while lines() >= 3 {
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        }
        XCTAssertTrue(rail.waitForNonExistence(timeout: 3), "Under three lines, Expand goes")
        checkBoxStill("Expand goes")

        type(untilLines: 3)
        XCTAssertTrue(rail.waitForExistence(timeout: 3))
        rail.tap()
        let expanded = app.textViews["chat.composer.expanded.text"]
        XCTAssertTrue(expanded.waitForExistence(timeout: 5), "Expand opens the expanded editor")
        XCTAssertTrue((expanded.value as? String)?.hasPrefix("WW") == true, "The editor has the draft")
        saveComposer("composer-expand-rail-opened-\(appearance)", app)
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
