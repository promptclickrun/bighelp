import XCTest

/// Unfolded "Ran code" steps on the demo data (`-test-code-tool`, #926): code as
/// a notebook cell with its output, long code folded, a shell command that
/// failed, and Python that printed one number, which once closed the app
/// (#924). `BIGHELP_CODE_CELL_EVIDENCE` saves screenshots there.
final class ToolCodeCellUITests: BighelpUITestCase {
    @MainActor
    func testCodeToolsUnfoldAsNotebookCells() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                                   "-test-code-tool",
                                   "-loopdy.chat.foldCompletedTurns", "NO",
                                   "-loopdy.demo.appearance", appearance]
            app.launch()
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 10))
            let python = app.buttons["chat.activity.code-tool-python"]
            if !python.waitForExistence(timeout: 3) {
                let trail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail."))
                    .firstMatch
                XCTAssertTrue(trail.waitForExistence(timeout: 5))
                reveal(trail, in: app).tap()
            }
            reveal(python, in: app).tap()

            let cell = "chat.activity.code-tool-python.code-cell"
            let code = element(cell + ".code", in: app)
            XCTAssertTrue(code.waitForExistence(timeout: 5))
            XCTAssertEqual(code.label, "Python code, 16 lines")
            XCTAssertFalse((code.value as? String ?? "").contains("Needs help"), "Code past 10 lines starts folded")
            XCTAssertTrue(element(cell + ".output", in: app).label.contains("Average: 84.5"))
            XCTAssertEqual(element(cell + ".outcome", in: app).label, "Output")
            save("python-folded-\(appearance)", app)

            let showAll = app.buttons[cell + ".show-all"]
            reveal(showAll, in: app).tap()
            XCTAssertEqual(showAll.label, "Show less")
            XCTAssertTrue((code.value as? String ?? "").contains("Needs help"), "Show all shows every line")
            save("python-all-lines-\(appearance)", app)

            reveal(app.buttons[cell + ".open"], in: app).tap()
            XCTAssertTrue(app.buttons["chat.code-reader.copy"].waitForExistence(timeout: 5))
            save("python-reader-\(appearance)", app)
            app.buttons["Done"].firstMatch.tap()

            let shell = app.buttons["chat.activity.code-tool-shell"]
            reveal(shell, in: app).tap()
            let shellOutcome = element("chat.activity.code-tool-shell.code-cell.outcome", in: app)
            XCTAssertTrue(shellOutcome.waitForExistence(timeout: 5))
            XCTAssertEqual(shellOutcome.label, "Exit code 1")
            XCTAssertEqual(element("chat.activity.code-tool-shell.code-cell.code", in: app).label, "Shell code, 1 line")

            let value = app.buttons["chat.activity.code-tool-value"]
            reveal(value, in: app).tap()
            let valueOutput = element("chat.activity.code-tool-value.code-cell.output", in: app)
            XCTAssertTrue(valueOutput.waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground, "Unfolding code that printed one number must not close the app")
            XCTAssertEqual(valueOutput.label.trimmingCharacters(in: .whitespacesAndNewlines), "84.5")
            reveal(valueOutput, in: app)
            save("shell-and-value-\(appearance)", app)
            app.terminate()
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Scrolls the chat until `element` can take a tap: on screen and above
    /// the message box, which floats over the chat's bottom and takes taps there.
    @MainActor @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let timeline = app.tables["chat.timeline"]
        let composer = app.descendants(matching: .any)["chat.composer-shell"].firstMatch
        func isClear() -> Bool {
            guard element.exists, element.isHittable else { return false }
            return element.frame.maxY < (composer.exists ? composer.frame.minY : app.frame.maxY)
        }
        for _ in 0..<10 where !isClear() {
            if element.exists, element.frame.midY < timeline.frame.midY {
                timeline.swipeDown(velocity: .slow)
            } else {
                timeline.swipeUp(velocity: .slow)
            }
        }
        return element
    }

    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_CODE_CELL_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
