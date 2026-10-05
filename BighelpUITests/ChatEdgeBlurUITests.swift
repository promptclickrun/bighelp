import UIKit
import XCTest

/// Messages scroll on under the chat's header, blurred, instead of vanishing behind a solid band
/// of color. The test reads the pixels beside ☰ before and after a short scroll: a solid band
/// never changes there, blurred messages do. BIGHELP_CHAT_EDGE_EVIDENCE (TEST_RUNNER_…) saves
/// the screenshots in light and dark.
final class ChatEdgeBlurUITests: BighelpUITestCase {
    @MainActor
    func testMessagesShowBlurredUnderTheHeader() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-long-transcript",
                                   // Every message on its own row, so they fill the screen.
                                   "-loopdy.chat.foldCompletedTurns", "NO", "-preview-ui-v3", "-test-companion-disabled",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let composer = app.textViews["chat.composer.text"]
            XCTAssertTrue(composer.waitForExistence(timeout: 20))
            let menu = app.buttons["chat.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            // Message text is a text view, not a static text.
            let latest = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "settled sentinel 1000"))
            XCTAssertTrue(latest.firstMatch.waitForExistence(timeout: 20))

            // Beside ☰, left of the avatar: only the backdrop and what scrolls under it.
            let frame = menu.frame
            let strip = CGRect(x: frame.maxX + 6, y: frame.minY + 4,
                               width: max(app.frame.width * 0.3 - frame.maxX - 6, 24), height: frame.height - 8)
            let before = try Self.luminance(of: app.screenshot().image, in: strip)
            save("chat-edge-\(appearance)-latest", app)

            // Scroll back a little, slowly enough that it doesn't fling.
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
            Thread.sleep(forTimeInterval: 1.5)
            let after = try Self.luminance(of: app.screenshot().image, in: strip)
            save("chat-edge-\(appearance)-scrolled", app)

            let change = zip(before, after).map { abs(Int($0) - Int($1)) }.reduce(0, +)
            let meanChange = Double(change) / Double(max(before.count, 1))
            XCTAssertGreaterThan(meanChange, 0.2,
                                 "\(appearance): the header hides the messages behind a solid fill")
            // The controls still work over the blur.
            XCTAssertTrue(menu.isHittable)
            XCTAssertTrue(composer.isHittable)
            app.terminate()
        }
    }

    /// Grey levels (0–255) of a part of the screen, given in points.
    private static func luminance(of image: UIImage, in rect: CGRect) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        let crop = try XCTUnwrap(cgImage.cropping(to: pixels))
        var values = [UInt8](repeating: 0, count: crop.width * crop.height)
        let drawn = values.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                          bitsPerComponent: 8, bytesPerRow: crop.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        XCTAssertTrue(drawn)
        return values
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CHAT_EDGE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
