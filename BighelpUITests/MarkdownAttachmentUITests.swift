import XCTest

/// A Markdown file an agent sent opens rendered, with Raw a tap away, and keeps Save and Share.
/// Set BIGHELP_MARKDOWN_EVIDENCE (TEST_RUNNER_…) to a folder to save the screenshots.
final class MarkdownAttachmentUITests: BighelpUITestCase {
    @MainActor
    func testMarkdownFileReadsRenderedOrRaw() throws {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-markdown-attachment",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let rendered = app.descendants(matching: .any)["chat.attachment.markdown.rendered"]
            XCTAssertTrue(rendered.waitForExistence(timeout: 15), "It opens rendered")
            XCTAssertTrue(app.staticTexts["Kyoto plan"].exists, "The heading reads as a heading, without its #")
            XCTAssertTrue(app.buttons["chat.attachment.save"].exists)
            XCTAssertTrue(app.buttons["chat.attachment.share"].waitForExistence(timeout: 5))
            save("markdown-preview-\(appearance)", app)

            app.segmentedControls["chat.attachment.markdown.mode"].buttons["Raw"].tap()
            let raw = app.descendants(matching: .any)["chat.attachment.markdown.raw"]
            XCTAssertTrue(raw.waitForExistence(timeout: 5))
            XCTAssertTrue((raw.label + (raw.value as? String ?? "")).contains("# Kyoto plan"), "Raw shows the source")
            save("markdown-raw-\(appearance)", app)
            app.terminate()
        }
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_MARKDOWN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
