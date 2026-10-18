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
