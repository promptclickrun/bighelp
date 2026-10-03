import UIKit
import XCTest

final class CompactChatComposerUITests: BighelpUITestCase {
    @MainActor
    func testSlashCommandsInLandscapeAndKeyboardDismissal() {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat",
            "-preview-ui-v3"]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && editor.frame.height > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        editor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        editor.typeText("/")
        let drawer = app.descendants(matching: .any)["reference-hub.drawer"].firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        let commands = app.buttons["reference-hub.filter.commands"]
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        commands.tap()
        let command = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reference-hub.command.")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        XCTAssertTrue(command.isHittable)
        XCTAssertGreaterThan(command.frame.height, 0)
        XCTAssertGreaterThanOrEqual(command.frame.minY, app.otherElements["chat.header-surface"].frame.maxY - 1)
        XCTAssertLessThanOrEqual(command.frame.maxY, keyboard.frame.minY + 1)
        XCTAssertEqual(editor.value as? String, "/")
        captureLandscape(app, name: "landscape-slash-visible-with-keyboard")
        let hierarchy = XCTAttachment(string: keyboard.debugDescription)
        hierarchy.name = "landscape-keyboard-controls"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let hideCandidates = keyboard.buttons.allElementsBoundByIndex.filter {
            $0.label.localizedCaseInsensitiveContains("hide keyboard") || $0.label.localizedCaseInsensitiveContains("dismiss keyboard")
        }
        guard let hide = hideCandidates.first, hide.isHittable else {
            XCTFail("No exposed keyboard-dismiss control. Inspect retained keyboard hierarchy and screenshot.")
            return
        }
        hide.tap()
        // iPad can retain a hidden Keyboard accessibility node. Require actual
        // key reachability, not destruction of that system-owned node.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !keyboard.exists || !keyboard.keys.firstMatch.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && keyboard.keys.firstMatch.isHittable
        }, object: nil)
        reopened.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 3), .completed)
        XCTAssertEqual(editor.value as? String, "/")
        captureLandscape(app, name: "landscape-slash-keyboard-stays-dismissed")
        editor.tap()
        let intentionalFocus = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            keyboard.exists && keyboard.keys.firstMatch.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [intentionalFocus], timeout: 5), .completed)
        captureLandscape(app, name: "landscape-after-deliberate-editor-tap")
        let keyboardStates = app.keyboards.allElementsBoundByIndex.map {
            "keyboard=\($0.frame), hittable=\($0.isHittable), keys=\($0.keys.count), firstKey=\($0.keys.firstMatch.label), keyHittable=\($0.keys.firstMatch.isHittable)"
        }.joined(separator: "\n")
        let keyboardStateAttachment = XCTAttachment(string: keyboardStates)
        keyboardStateAttachment.name = "after-tap-keyboard-states"
        keyboardStateAttachment.lifetime = .keepAlways
        add(keyboardStateAttachment)
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        commands.tap()
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 5))
        XCTAssertTrue(keyboard.exists)
        editor.typeText("after")
        XCTAssertTrue((editor.value as? String)?.hasSuffix("after") == true)
    }
    @MainActor
    func testLandscapeKeyboardKeepsEditorAndActionsClearOfHeader() {
        exerciseClearance(longDraft: false)
    }

    @MainActor
    func testLongLandscapeDraftKeepsNativeViewportAndActionsClear() {
        exerciseClearance(longDraft: true)
    }

    @MainActor
    func testCompactSessionMenuKeepsContextPresentedAfterKeyboardDismissal() {
        let app = openCompactSessionMenu()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["chat.composer.menu.context"].tap()
        XCTAssertTrue(app.staticTexts["Context used"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        let context = app.descendants(matching: .any)["chat.session-context.popover"].firstMatch
        XCTAssertTrue(context.exists)
        XCTAssertTrue(app.staticTexts["Context used"].isHittable)
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String, "Keep this session draft.")
        captureLandscape(app, name: "compact-session-menu-context-retained")
    }

    @MainActor
    func testCompactSessionMenuOpensChangesWithoutLosingDraft() {
        let app = openCompactSessionMenu()
        defer { XCUIDevice.shared.orientation = .portrait }
        // File changes moved to the chat's ⋯ menu; close the session menu first.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        chatMenuItem("chat.file-changes", in: app).tap()
        let panel = app.otherElements["project-changes.panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        captureLandscape(app, name: "compact-session-menu-changes")
        let close = app.buttons["Close project changes"]
        if close.exists {
            XCTAssertTrue(close.isHittable)
            close.tap()
        } else {
            let back = app.buttons["BackButton"]
            XCTAssertTrue(back.exists)
            XCTAssertTrue(back.isHittable)
            back.tap()
        }
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.textViews["chat.composer.text"].value as? String, "Keep this session draft.")
    }

    @MainActor
    private func openCompactSessionMenu() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays", "-preview-simple-chat", "-preview-ui-v3", "-test-v3-header-context",
            "-enable-project-changes", "-use-project-changes-markdown-fixture"
        ]
        app.launch()
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Keep this session draft.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && editor.frame.height > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        let menu = app.buttons["chat.composer.session-actions"]
        XCTAssertTrue(menu.exists)
        XCTAssertTrue(menu.isHittable)
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.minY, app.otherElements["chat.header-surface"].frame.maxY)
        XCTAssertLessThanOrEqual(menu.frame.maxY, app.tables["chat.timeline"].frame.maxY)
        menu.tap()
        XCTAssertTrue(app.buttons["chat.composer.menu.context"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.composer.menu.changes"].exists, "File changes live in the ⋯ menu")
        return app
    }

    @MainActor
    private func exerciseClearance(longDraft: Bool) {
        let app = makeApp()
        app.launchArguments = [
            "-use-demo-fixtures", "-disable-demo-delays",
            "-loopdy.appearance.theme", "loopdy", "-loopdy.demo.appearance", "light"
        ]
        app.launch()
        let workspace = app.buttons["home.drawer.open"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        workspace.tap()
        app.buttons["menu.new-chat"].tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Before /")
        let drawer = app.otherElements["reference-hub.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        app.buttons["reference-hub.filter.commands"].tap()
        let command = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "reference-hub.command."
        )).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5))
        command.tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 3))
        editor.typeText("after")
        if longDraft {
            editor.typeText("\nFirst line of a longer draft.\nSecond line stays intact.\nThird line keeps the native caret.")
        }
        let draft = editor.value as? String

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && editor.frame.height > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(editor.value as? String, draft)

        let header = app.otherElements["chat.header-surface"]
        let timeline = app.tables["chat.timeline"]
        let keyboard = app.keyboards.firstMatch
        let composer = app.otherElements["chat.composer-shell"]
        let controls = [
            app.buttons["chat.attachment"].firstMatch,
            app.buttons["chat.session-controls"].firstMatch,
            app.buttons["chat.composer.expand"].firstMatch,
            app.buttons["chat.send"].firstMatch,
            app.buttons["chat.composer.session-actions"].firstMatch
        ]
        XCTAssertTrue(header.exists)
        XCTAssertTrue(timeline.exists)
        XCTAssertTrue(composer.exists)
        let availableBottom = min(timeline.frame.maxY, keyboard.frame.minY)
        var geometry = """
        app=\(app.frame)
        header=\(header.frame)
        timeline=\(timeline.frame)
        keyboard=\(keyboard.frame)
        composer=\(composer.frame)
        editor=\(editor.frame), value=\(String(describing: editor.value))
        availableBottom=\(availableBottom)
        """
        XCTAssertGreaterThanOrEqual(composer.frame.minY, header.frame.maxY)
        XCTAssertLessThanOrEqual(composer.frame.maxY, availableBottom)
        XCTAssertGreaterThanOrEqual(editor.frame.minY, header.frame.maxY)
        XCTAssertLessThanOrEqual(editor.frame.maxY, availableBottom)
        XCTAssertGreaterThan(editor.frame.height, 0)
        XCTAssertTrue(editor.isHittable)
        for control in controls {
            XCTAssertTrue(control.exists, control.identifier)
            XCTAssertTrue(control.isHittable, control.identifier)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, control.identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, control.identifier)
            XCTAssertTrue(app.frame.contains(control.frame), control.identifier)
            XCTAssertGreaterThanOrEqual(control.frame.minY, header.frame.maxY, control.identifier)
            XCTAssertLessThanOrEqual(control.frame.maxY, availableBottom, control.identifier)
            geometry += "\n\(control.identifier)=\(control.frame), hittable=\(control.isHittable)"
        }
        XCTAssertFalse(editor.frame.intersects(app.buttons["chat.composer.expand"].frame))
        XCTAssertFalse(app.otherElements["primary-navigation"].exists)
        let measurement = XCTAttachment(string: geometry)
        measurement.name = "compact-chat-header-composer-clearance"
        measurement.lifetime = .keepAlways
        add(measurement)
        captureLandscape(app, name: longDraft ? "compact-chat-long-keyboard-clearance" : "compact-chat-keyboard-clearance")

        editor.typeText(" kept")
        XCTAssertEqual(editor.value as? String, (draft ?? "") + " kept")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        openChatWorkspaceMenu(in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu.agents"].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, (draft ?? "") + " kept")
    }

    @MainActor
    private func captureLandscape(_ app: XCUIApplication, name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let image = screenshot.image
        let geometry = XCTAttachment(string: """
        app=\(app.frame)
        windows=\(app.windows.allElementsBoundByIndex.map(\.frame))
        image.size=\(image.size), scale=\(image.scale), orientation=\(image.imageOrientation.rawValue)
        image.pixels=\(image.cgImage?.width ?? 0)x\(image.cgImage?.height ?? 0)
        """)
        geometry.name = name + "-capture-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertGreaterThan(image.size.width, image.size.height)
        XCTAssertEqual(image.size.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(image.size.height, app.frame.height, accuracy: 1)
        guard image.size.width > image.size.height,
              abs(image.size.width - app.frame.width) <= 1,
              abs(image.size.height - app.frame.height) <= 1 else {
            let invalid = XCTAttachment(screenshot: screenshot)
            invalid.name = name + "-invalid-source"
            invalid.lifetime = .keepAlways
            add(invalid)
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
        let evidence = XCTAttachment(image: upright)
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
